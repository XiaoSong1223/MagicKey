#!/bin/bash
#
# 建一个**固定的**本地代码签名身份，让开发期的 TCC 授权不再每次构建都失效。
#
# ## 为什么需要它
#
# ad-hoc 签名（`codesign --sign -`）的指定要求就是二进制哈希本身：
#
#     codesign -d -r- MagicKey.app
#     # → designated => cdhash H"938f5197…"
#
# TCC 在授权那一刻把这条要求存进记录。改一行代码重新编译，cdhash 就变了，
# 记录再也匹配不上——系统设置里那个开关**看着还是开的**，应用却查到未授权。
# 「输入监控」「系统录音」都吃这一套，每次 `make install` 都要重授一遍。
#
# 用一张固定的自签名证书签，指定要求变成
#
#     designated => identifier "io.github.xiaosong1223.MagicKey"
#                   and certificate leaf H"<证书哈希>"
#
# 和二进制内容无关，**重新编译不再影响它**。Developer ID 是同一个机制，
# 这里只是把证书换成本地自签的。
#
# ## 这个脚本不做什么
#
# 不解决分发问题。自签名证书别人机器上不认，Gatekeeper 照样拦。
# 要发布仍然需要 Apple Developer ID + 公证。
#
# 用法：bash tools/dev-signing-identity.sh
# 撤销：bash tools/dev-signing-identity.sh --remove

set -euo pipefail

CN="MagicKey Local Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

find_sha1() {
    security find-certificate -c "$CN" -Z "$KEYCHAIN" 2>/dev/null \
        | sed -n 's/^SHA-1 hash: //p' | head -1
}

if [ "${1:-}" = "--remove" ]; then
    sha1="$(find_sha1 || true)"
    if [ -z "$sha1" ]; then
        echo "没有找到「${CN}」，无需删除。"
        exit 0
    fi
    # 信任设置和身份是两份记录，删身份不会顺带删信任——留着是无害的孤儿，
    # 但重建时 add-trusted-cert 会因指纹不同再弹一次对话框，删干净省一步。
    security find-certificate -c "$CN" -p "$KEYCHAIN" > "$WORK/old-cert.pem" 2>/dev/null || true
    [ -s "$WORK/old-cert.pem" ] && security remove-trusted-cert "$WORK/old-cert.pem" 2>/dev/null || true
    security delete-identity -Z "$sha1" "$KEYCHAIN"
    echo "已删除「${CN}」。下次 make install 会自动退回 ad-hoc 签名。"
    exit 0
fi

if [ -n "$(find_sha1 || true)" ]; then
    echo "「${CN}」已经在钥匙串里了，不重复创建。"
    echo "要重建先跑：bash tools/dev-signing-identity.sh --remove"
    exit 0
fi

echo "==> 1/5 生成自签名证书（20 年有效期，仅用于本机开发）"
# 三个扩展都不能少：codeSigning 的 EKU 是 codesign 认这张证书的前提，
# CA:false + digitalSignature 是叶子证书的常规约束。
openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$CN/O=MagicKey/C=CN" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export -out "$WORK/id.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$CN" -passout pass:magickey

echo "==> 2/5 导入登录钥匙串"
# -T /usr/bin/codesign：把 codesign 加进这把私钥的访问白名单。
# 少了它，每次签名都会弹「codesign 想要使用您钥匙串中的密钥」。
security import "$WORK/id.p12" -k "$KEYCHAIN" -P magickey -T /usr/bin/codesign >/dev/null
echo "    已导入。"

echo "==> 3/5 信任这张证书用于代码签名（会弹一次系统对话框，输登录密码确认）"
# **这一步 2026-08-25 之前是缺的，而且缺得毫无声响**：openssl 自签的证书
# 导入后没有任何信任设置，身份状态是 CSSMERR_TP_NOT_TRUSTED，codesign 直接拒签
# ——第 5 步会失败，但错误长得和「访问控制没放行」一模一样，指错方向。
# Keychain Access 的证书助理建证书时会自动做这一步，openssl 不会。
# 修改信任设置是系统门槛，无法静默，对话框必弹。
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"
echo "    已信任。"

echo "==> 4/5 允许 codesign 无提示使用这把私钥"
# 非交互环境（CI、无 TTY 的代理 shell）读不到密码：跳过而不是死掉——
# `set -e` 下裸 read 撞到 EOF 会让整个脚本无声退出，前面已导入的一半留在钥匙串里，
# 重跑还会被开头的「已存在」拦住，特别坑。
if [ -t 0 ]; then
    echo "    ⚠️  这一步要你的**登录密码**（就是开机/解锁那个），"
    echo "        输入时不显示字符。跳过的话第一次签名会弹一次钥匙串授权框。"
    printf "    登录密码（直接回车跳过）: "
    read -rs PW || PW=""
    echo
else
    echo "    （stdin 不是终端，跳过。第一次签名时弹的授权框里点「始终允许」，效果相同。）"
    PW=""
fi
if [ -n "$PW" ]; then
    security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -k "$PW" "$KEYCHAIN" >/dev/null 2>&1 \
        && echo "    已设置，之后签名不再弹框。" \
        || echo "    ⚠️  设置失败（密码不对？）。签名仍可用，只是每次会弹一次授权框。"
    unset PW
fi

echo "==> 5/5 验证：签一份临时副本，看指定要求变了没有"
mkdir -p "$WORK/T.app/Contents/MacOS"
printf '#!/bin/sh\ntrue\n' > "$WORK/T.app/Contents/MacOS/T"
chmod +x "$WORK/T.app/Contents/MacOS/T"
cat > "$WORK/T.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.xiaosong1223.MagicKeyCertTest</string>
<key>CFBundleExecutable</key><string>T</string>
</dict></plist>
PLIST

if ! codesign --force --sign "$CN" "$WORK/T.app" 2>/dev/null; then
    echo "    ❌ 用这张证书签名失败。"
    echo "       多半是钥匙串里的访问控制没放行；重跑本脚本并在第 3 步输入密码。"
    exit 1
fi

DR="$(codesign -d -r- "$WORK/T.app" 2>&1 | sed -n 's/^# designated => //p')"
echo "    指定要求：$DR"
case "$DR" in
    # 自签证书的叶就是根，codesign 打出来的是 "certificate root" 不是
    # "certificate leaf"（Developer ID 那种链式证书才是 leaf）。两者都对：
    # 判据是「绑证书哈希、与二进制内容无关」，不是那个词。
    *"certificate leaf"*|*"certificate root"*)
        echo
        echo "✅ 成了。指定要求绑的是证书，不是二进制哈希。"
        echo "   下次 make install 会自动用这张证书签（Makefile 会检测），"
        echo "   **那一次仍会让现有授权失效——重授最后一遍**，之后就稳定了。"
        ;;
    *cdhash*)
        echo
        echo "❌ 仍然是 cdhash，证书没生效，白做。别急着重授权，先来查原因。"
        exit 1
        ;;
    *)
        echo
        echo "⚠️  没认出这条指定要求，人工看一眼上面那行。"
        ;;
esac
