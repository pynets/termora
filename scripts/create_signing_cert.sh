#!/usr/bin/env bash

# ==============================================================================
# 创建 Termora 自签名代码签名证书（一次性操作）
# 用途：保证每次构建使用相同的签名身份，macOS TCC 权限在升级后不失效
# ==============================================================================

set -e

CERT_NAME="Termora Self-Signed"

# 检查是否已存在
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "✅ 证书 \"$CERT_NAME\" 已存在，无需重复创建。"
  security find-identity -v -p codesigning | grep "$CERT_NAME"
  exit 0
fi

echo "正在创建自签名代码签名证书: $CERT_NAME"
echo ""

# 生成证书和私钥
TMPDIR_CERT=$(mktemp -d)
CERT_PEM="$TMPDIR_CERT/cert.pem"
KEY_PEM="$TMPDIR_CERT/key.pem"
P12_FILE="$TMPDIR_CERT/cert.p12"

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$KEY_PEM" -out "$CERT_PEM" \
  -days 3650 -subj "/CN=$CERT_NAME/O=Termora" \
  -addext "keyUsage=digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" 2>/dev/null

# 打包为 p12（使用临时密码以兼容新版 macOS security 工具）
TEMP_PASS="termora-setup-$(date +%s)"
openssl pkcs12 -export -out "$P12_FILE" \
  -inkey "$KEY_PEM" -in "$CERT_PEM" \
  -passout "pass:$TEMP_PASS" \
  -legacy 2>/dev/null || \
openssl pkcs12 -export -out "$P12_FILE" \
  -inkey "$KEY_PEM" -in "$CERT_PEM" \
  -passout "pass:$TEMP_PASS" 2>/dev/null

# 导入到登录钥匙串
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if [ ! -f "$KEYCHAIN" ]; then
  KEYCHAIN="$HOME/Library/Keychains/login.keychain"
fi

echo "📋 正在导入证书到钥匙串（可能需要输入 Mac 登录密码）..."
security import "$P12_FILE" -k "$KEYCHAIN" -T /usr/bin/codesign -P "$TEMP_PASS"

echo "📋 正在设置证书为代码签名可信..."
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT_PEM" || true

# 允许 codesign 无提示访问
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" 2>/dev/null || true

# 清理临时文件
rm -rf "$TMPDIR_CERT"

# 验证
echo ""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "✅ 证书创建成功！"
  security find-identity -v -p codesigning | grep "$CERT_NAME"
  echo ""
  echo "后续每次运行 ./release.sh 会自动使用此证书签名，升级后 TCC 权限不再丢失。"
else
  echo "❌ 自动创建失败。请手动在"钥匙串访问"中创建："
  echo ""
  echo "  1. 打开「钥匙串访问」→ 菜单「钥匙串访问」→「证书助理」→「创建证书…」"
  echo "  2. 名称输入: $CERT_NAME"
  echo "  3. 证书类型选择: 代码签名 (Code Signing)"
  echo "  4. 点击「创建」即可"
  echo ""
  echo "  创建完成后重新运行 ./release.sh 即可。"
  exit 1
fi
