#!/bin/bash
# 钥匙串里能签名的证书（看有没有 Developer ID Application）、各自是哪个 team；Xcode 登了哪些账号；gh 和仓库。
security find-identity -v -p codesigning
for name in "Apple Development: popicofe" "Apple Development: tloudalo"; do
  echo "--- $name: $(security find-certificate -c "$name" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)"
done
echo "--- xcode teams:"
defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | grep -E "teamID|teamName|teamType|isFreeProvisioningTeam" | sort -u | head -20
defaults read com.apple.dt.Xcode IDEProvisioningTeams 2>/dev/null | grep -E "teamID|teamName|teamType|isFreeProvisioningTeam" | sort -u | head -20
echo "--- git: $(git -C . rev-parse --show-toplevel 2>&1) $(git -C . remote -v 2>&1 | head -2 | tr '\n' ' ')"
echo "--- repo: $(gh repo view omniomo/eyeline --json name,visibility,url 2>&1 | head -3)"
echo "--- orgs: $(gh api user/orgs --jq '.[].login' 2>&1 | tr '\n' ' ')"
