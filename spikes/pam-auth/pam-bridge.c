#include "pam-bridge.h"

#include <security/pam_appl.h>
#include <string.h>
#include <stdlib.h>

// Conversation callback: PAM asks for the password, we hand back the one
// already collected (with echo disabled) by the Swift side. No prompting or
// logging happens here.
static int conversation(int num_msg, const struct pam_message **msg,
                         struct pam_response **resp, void *appdata_ptr) {
    if (num_msg <= 0) {
        return PAM_CONV_ERR;
    }

    struct pam_response *responses = calloc((size_t)num_msg, sizeof(struct pam_response));
    if (responses == NULL) {
        return PAM_BUF_ERR;
    }

    const char *password = (const char *)appdata_ptr;
    for (int i = 0; i < num_msg; i++) {
        if (msg[i]->msg_style == PAM_PROMPT_ECHO_OFF) {
            responses[i].resp = strdup(password);
        } else {
            responses[i].resp = NULL;
        }
        responses[i].resp_retcode = 0;
    }

    *resp = responses;
    return PAM_SUCCESS;
}

int pamAuthenticate(const char *username, const char *password) {
    struct pam_conv conv = {conversation, (void *)password};
    pam_handle_t *handle = NULL;

    int status = pam_start("login", username, &conv, &handle);
    if (status != PAM_SUCCESS) {
        return status;
    }

    status = pam_authenticate(handle, 0);
    pam_end(handle, status);
    return status;
}
