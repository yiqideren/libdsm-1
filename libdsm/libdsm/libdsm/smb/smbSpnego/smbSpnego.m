//
//  smbSpnego.m
//  test
//
//  Created by trekvn on 4/13/17.
//  Copyright © 2017 trekvn. All rights reserved.
//

#import "smbSpnego.h"
#import "libtasn1.h"
#import "spnego_asn1.h"

static const char spnego_oid[]  = "1.3.6.1.5.5.2";
static const char ntlmssp_oid[] = "1.3.6.1.4.1.311.2.2.10";

@implementation smbSpnego

static void asn1_display_error(const char *where, int errcode) {
    // Avoids warning when not in debug mode
    (void)where;
    (void)errcode;
}

static int init_asn1(smb_session *s)
{
    int           res;
    
    assert(s != NULL);
    
    if (s->spnego_asn1 != NULL)
        return DSM_ERROR_GENERIC;
    
    res = asn1_array2tree(spnego_asn1_conf, &s->spnego_asn1, NULL);
    
    if (res != ASN1_SUCCESS)
    {
        asn1_display_error("init_asn1", res);
        return DSM_ERROR_GENERIC;
    } else {
        return DSM_SUCCESS;
    }
}

static void clean_asn1(smb_session *s)
{
    assert(s != NULL);
    
    if (s->spnego_asn1 != NULL)
        asn1_delete_structure(&s->spnego_asn1);
}

static int negotiate(smb_session *s, const char *domain)
{
    smb_message           *msg = NULL;
    smb_session_xsec_req  req;
    smb_buffer            ntlm;
    ASN1_TYPE             token;
    int                   res, der_size = 128;
    char                  der[128], err_desc[ASN1_MAX_ERROR_DESCRIPTION_SIZE];
    
    msg = smb_message_new(SMB_CMD_SETUP);
    if (!msg)
        return DSM_ERROR_GENERIC;
    
    // this struct will be set at the end when we know the payload size
    SMB_MSG_ADVANCE_PKT(msg, smb_session_xsec_req);
    
    asn1_create_element(s->spnego_asn1, "SPNEGO.GSSAPIContextToken", &token);
    
    res = asn1_write_value(token, "thisMech", spnego_oid, 1);
    if (res != ASN1_SUCCESS) goto error;
    res = asn1_write_value(token, "spnego", "negTokenInit", 1);
    if (res != ASN1_SUCCESS) goto error;
    res = asn1_write_value(token, "spnego.negTokenInit.mechTypes", "NEW", 1);
    if (res != ASN1_SUCCESS) goto error;
    res = asn1_write_value(token, "spnego.negTokenInit.mechTypes.?1", ntlmssp_oid, 1);
    if (res != ASN1_SUCCESS) goto error;
    res = asn1_write_value(token, "spnego.negTokenInit.reqFlags", NULL, 0);
    if (res != ASN1_SUCCESS) goto error;
    res = asn1_write_value(token, "spnego.negTokenInit.mechListMIC", NULL, 0);
    if (res != ASN1_SUCCESS) goto error;
    
    smb_ntlmssp_negotiate(domain, domain, &ntlm);
    res = asn1_write_value(token, "spnego.negTokenInit.mechToken", ntlm.data,
                           ntlm.size);
    smb_buffer_free(&ntlm);
    if (res != ASN1_SUCCESS) goto error;
    
    res = asn1_der_coding(token, "", der, &der_size, err_desc);
    if (res != ASN1_SUCCESS)
    {
        smb_message_destroy(msg);
        return DSM_ERROR_GENERIC;
    }
    
    smb_message_append(msg, der, der_size);
    smb_message_put_utf16(msg, SMB_OS, strlen(SMB_OS));
    smb_message_put16(msg, 0);
    smb_message_put_utf16(msg, SMB_LANMAN, strlen(SMB_LANMAN));
    smb_message_put16(msg, 0);
    smb_message_put16(msg, 0);
    
    SMB_MSG_INIT_PKT_ANDX(req);
    req.wct              = 12;
    req.max_buffer       = SMB_SESSION_MAX_BUFFER;
    req.mpx_count        = 16;
    req.vc_count         = 1;
    req.caps             = s->srv.caps;
    req.session_key      = s->srv.session_key;
    req.xsec_blob_size = der_size;
    req.payload_size   = msg->cursor - sizeof(smb_session_xsec_req);
    SMB_MSG_INSERT_PKT(msg, 0, req);
    
    asn1_delete_structure(&token);
    
    if (!smb_session_send_msg(s, msg))
    {
        smb_message_destroy(msg);
        return DSM_ERROR_NETWORK;
    }
    
    smb_message_destroy(msg);
    return DSM_SUCCESS;
    
error:
    asn1_display_error("smb_session_login negotiate()", res);
    smb_message_destroy(msg);
    return DSM_ERROR_GENERIC;
}

static int      challenge(smb_session *s)
{
    char                  err_desc[ASN1_MAX_ERROR_DESCRIPTION_SIZE];
    char                  resp_token[256];
    smb_message           msg;
    smb_session_xsec_resp *resp;
    smb_ntlmssp_challenge *challenge;
    ASN1_TYPE             token;
    int                   res, resp_token_size = 256;
    
    assert(s != NULL);
    
    if (smb_session_recv_msg(s, &msg) == 0)
    {
        return DSM_ERROR_NETWORK;
    }
    
    if (msg.packet->header.status != NT_STATUS_MORE_PROCESSING_REQUIRED)
    {
        return DSM_ERROR_GENERIC;
    }
    
    resp = (smb_session_xsec_resp *)msg.packet->payload;
    
    asn1_create_element(s->spnego_asn1, "SPNEGO.NegotiationToken", &token);
    res = asn1_der_decoding(&token, resp->payload, resp->xsec_blob_size,
                            err_desc);
    if (res != ASN1_SUCCESS)
    {
        asn1_delete_structure(&token);
        asn1_display_error("NegTokenResp parsing", res);
        return DSM_ERROR_GENERIC;
    }
    
    // XXX Check the value of "negTokenResp.negResult"
    
    res = asn1_read_value(token, "negTokenResp.responseToken", resp_token,
                          &resp_token_size);
    asn1_delete_structure(&token);
    if (res != ASN1_SUCCESS)
    {
        asn1_display_error("NegTokenResp read responseToken", res);
        return DSM_ERROR_GENERIC;
    }
    
    // We got the server challenge, yeaaah.
    challenge = (smb_ntlmssp_challenge *)resp_token;
    if (smb_buffer_alloc(&s->xsec_target, challenge->tgt_len) == 0)
        return DSM_ERROR_GENERIC;
    memcpy(s->xsec_target.data,
           challenge->data + challenge->tgt_offset - sizeof(smb_ntlmssp_challenge),
           s->xsec_target.size);
    s->srv.challenge = challenge->challenge;
    s->srv.uid       = msg.packet->header.uid;
    
    
    return DSM_SUCCESS;
}

static int      auth(smb_session *s, const char *domain, const char *user,
                     const char *password)
{
    smb_message           *msg = NULL, resp;
    smb_session_xsec_req  req;
    smb_buffer            ntlm;
    ASN1_TYPE             token;
    int                   res, der_size = 512;
    char                  der[512], err_desc[ASN1_MAX_ERROR_DESCRIPTION_SIZE];
    
    msg = smb_message_new(SMB_CMD_SETUP);
    if (!msg)
        return DSM_ERROR_GENERIC;
    
    // this struct will be set at the end when we know the payload size
    SMB_MSG_ADVANCE_PKT(msg, smb_session_xsec_req);
    
    asn1_create_element(s->spnego_asn1, "SPNEGO.NegotiationToken", &token);
    
    // Select a response message type
    res = asn1_write_value(token, "", "negTokenResp", 1);
    if (res != ASN1_SUCCESS) goto error;
    
    // Delete all optionnal field except 'ResponseToken'
    res = asn1_write_value(token, "negTokenResp.negResult", NULL, 0);
    if (res != ASN1_SUCCESS) goto error;
    res = asn1_write_value(token, "negTokenResp.supportedMech", NULL, 0);
    if (res != ASN1_SUCCESS) goto error;
    res = asn1_write_value(token, "negTokenResp.mechListMIC", NULL, 0);
    if (res != ASN1_SUCCESS) goto error;
    
    
    smb_ntlmssp_response(s->srv.challenge, s->srv.ts - 4200, domain, domain, user,
                         password, &s->xsec_target, &ntlm);
    res = asn1_write_value(token, "negTokenResp.responseToken", ntlm.data,
                           ntlm.size);
    smb_buffer_free(&ntlm);
    if (res != ASN1_SUCCESS) goto error;
    
    res = asn1_der_coding(token, "", der, &der_size, err_desc);
    if (res != ASN1_SUCCESS)
    {
        smb_message_destroy(msg);
        return DSM_ERROR_GENERIC;
    }
    
    smb_message_append(msg, der, der_size);
    if (msg->cursor % 2)
        smb_message_put8(msg, 0);
    smb_message_put_utf16(msg, SMB_OS, strlen(SMB_OS));
    smb_message_put16(msg, 0);
    smb_message_put_utf16(msg, SMB_LANMAN, strlen(SMB_LANMAN));
    smb_message_put16(msg, 0);
    smb_message_put16(msg, 0); // Empty PDC name
    
    SMB_MSG_INIT_PKT_ANDX(req);
    req.wct              = 12;
    req.max_buffer       = SMB_SESSION_MAX_BUFFER;
    req.mpx_count        = 16; // XXX ?
    req.vc_count         = 1;
    req.caps             = s->srv.caps; // XXX caps & our_caps_mask
    req.session_key      = s->srv.session_key;
    req.xsec_blob_size = der_size;
    req.payload_size   = msg->cursor - sizeof(smb_session_xsec_req);
    SMB_MSG_INSERT_PKT(msg, 0, req);
    
    asn1_delete_structure(&token);
    
    if (!smb_session_send_msg(s, msg))
    {
        smb_message_destroy(msg);
        return DSM_ERROR_NETWORK;
    }
    smb_message_destroy(msg);
    
    if (smb_session_recv_msg(s, &resp) == 0)
        return DSM_ERROR_NETWORK;
    
    if (!smb_session_check_nt_status(s, &resp))
        return DSM_ERROR_NT;
    else
    {
        smb_session_xsec_resp *r = (smb_session_xsec_resp *)resp.packet->payload;
        if (r->action & 0x0001)
            s->guest = true;
        
        s->srv.uid  = resp.packet->header.uid;
        s->logged = true;
        
        return DSM_SUCCESS;
    }
    
error:
    asn1_display_error("smb_session_login auth()", res);
    smb_message_destroy(msg);
    return DSM_ERROR_GENERIC;
}
#pragma mark - smbSessionLoginSpnego
int smb_session_login_spnego(smb_session *s, const char *domain,
                                         const char *user, const char *password)
{
    int res;
    assert(s != NULL && domain != NULL && user != NULL && password != NULL);
    
    // Clear User ID that might exists from previous authentication attempt
    s->srv.uid = 0;
    
    if (init_asn1(s) != DSM_SUCCESS)
        return DSM_ERROR_GENERIC;
    
    if ((res = negotiate(s, domain)) != DSM_SUCCESS)
        goto error;
    if ((res = challenge(s)) != DSM_SUCCESS)
        goto error;
    
    res = auth(s, domain, user, password);
    
    clean_asn1(s);
    
    s->logged = true;
    return res;
    
error:
    clean_asn1(s);
    return res;
}
@end
