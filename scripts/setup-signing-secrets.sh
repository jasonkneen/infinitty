#!/bin/zsh
# One-time: store CI signing secrets for the release workflow.
#
# Export the cert FIRST via Keychain Access (GUI) — exporting from the CLI
# grabs every identity in the keychain and blows GitHub's 48KB secret limit:
#   Keychain Access -> My Certificates -> "Developer ID Application: Jason
#   Kneen" -> right-click -> Export -> .p12 with a password.
#
# Then: scripts/setup-signing-secrets.sh ~/Desktop/cert.p12
set -euo pipefail

P12="${1:?usage: setup-signing-secrets.sh <path-to-cert.p12>}"
SIZE=$(stat -f %z "$P12")
if [ "$SIZE" -gt 20000 ]; then
  echo "That p12 is ${SIZE} bytes — it likely contains multiple identities."
  echo "Export ONLY the Developer ID Application cert from Keychain Access."
  exit 1
fi

read -s "P12PASS?Password you set when exporting the .p12: "; echo
gh secret set MAC_CERT_P12_BASE64 --repo jasonkneen/infinitty --body "$(base64 -i "$P12")"
gh secret set MAC_CERT_PASSWORD   --repo jasonkneen/infinitty --body "$P12PASS"

read "APPLEID?Apple ID email: "
gh secret set APPLE_ID --repo jasonkneen/infinitty --body "$APPLEID"
echo "App-specific password: appleid.apple.com -> Sign-In & Security -> App-Specific Passwords"
read -s "APPPASS?App-specific password: "; echo
gh secret set APPLE_APP_SPECIFIC_PASSWORD --repo jasonkneen/infinitty --body "$APPPASS"
gh secret set APPLE_TEAM_ID --repo jasonkneen/infinitty --body "SW75ZJJ5R6"

echo ""
echo "Signing secrets set. Don't forget NPM_TOKEN if not already set:"
echo "  gh secret set NPM_TOKEN --repo jasonkneen/infinitty"
echo "Then: git tag v0.1.0 && git push origin v0.1.0"
echo "Finally: rm '$P12'"
