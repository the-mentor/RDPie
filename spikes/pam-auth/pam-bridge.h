#ifndef PAM_BRIDGE_H
#define PAM_BRIDGE_H

// Returns 0 (PAM_SUCCESS) on a correct password, non-zero PAM error code
// otherwise. Never logs the password.
int pamAuthenticate(const char *username, const char *password);

#endif
