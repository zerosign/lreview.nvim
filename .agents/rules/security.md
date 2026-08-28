# Security Rules: Secret and Token Protection

These rules apply whenever this workspace is active to prevent accidental exposure of credentials.

## Rules

- **Never Print Tokens or Secrets:** Never output raw personal access tokens, OAuth tokens, SSH keys, passwords, or other credentials in the assistant's text messages or command parameters shown in chat.
- **Mask Output:** If a command output returns a token or secret, mask it (e.g. replacing the characters with `[REDACTED]`) before displaying it to the user.
- **Environment and Auth Credentials:** Never ask the user to input tokens in plaintext, and never run commands that print raw tokens (e.g., `gh auth token` or `glab auth token`) unless the output is explicitly piped, redirected to a file, or masked.
