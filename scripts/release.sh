#!/usr/bin/env bash

# ==============================================================================
# Termora — 一键全自动版本发布脚本 (自动化改版本号、编译打包 DMG、Git提交、上传GitHub Release)
# 使用方法:
#   ./scripts/release.sh 0.0.3          # 指定发布版本号 0.0.3
#   ./scripts/release.sh 0.0.3 3        # 指定版本号 0.0.3 和构建号 3 (默认构建号自动加1)
# ==============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}======================================================================${NC}"
echo -e "${CYAN}                🚀 Termora 一键打包及自动化发布工具                   ${NC}"
echo -e "${CYAN}======================================================================${NC}"

# 1. 检查或读取版本号
NEW_VERSION=$1
BUILD_NUMBER=$2

# 如果未传入参数，交互式询问版本号
if [ -z "$NEW_VERSION" ]; then
  # 从 pubspec.yaml 读取当前版本
  CURRENT_FULL_VER=$(grep "^version:" pubspec.yaml | head -n 1 | awk '{print $2}')
  echo -e "${YELLOW}当前 pubspec.yaml 版本为: ${GREEN}${CURRENT_FULL_VER}${NC}"
  read -p "请输入目标发布的版本号 (例如 0.0.3): " NEW_VERSION
  if [ -z "$NEW_VERSION" ]; then
    echo -e "${RED}错误: 版本号不能为空，退出脚本。${NC}"
    exit 1
  fi
fi

# 移除开头的 v (如用户输入 v0.0.3)
NEW_VERSION=${NEW_VERSION#v}

# 如果没有传 Build Number，自动提取当前 build number + 1
if [ -z "$BUILD_NUMBER" ]; then
  CURRENT_FULL_VER=$(grep "^version:" pubspec.yaml | head -n 1 | awk '{print $2}')
  OLD_BUILD=$(echo "$CURRENT_FULL_VER" | cut -d '+' -f 2)
  if [[ "$OLD_BUILD" =~ ^[0-9]+$ ]]; then
    BUILD_NUMBER=$((OLD_BUILD + 1))
  else
    BUILD_NUMBER=1
  fi
fi

FULL_VERSION="${NEW_VERSION}+${BUILD_NUMBER}"
TAG_NAME="v${NEW_VERSION}"
DMG_NAME="Termora-${TAG_NAME}-macOS.dmg"

echo -e "\n${BLUE}👉 目标发布信息:${NC}"
echo -e "   - 版本号    : ${GREEN}${NEW_VERSION}${NC}"
echo -e "   - 构建号    : ${GREEN}${BUILD_NUMBER}${NC}"
echo -e "   - 完整版本  : ${GREEN}${FULL_VERSION}${NC}"
echo -e "   - Git Tag   : ${GREEN}${TAG_NAME}${NC}"
echo -e "   - 安装包名  : ${GREEN}${DMG_NAME}${NC}"

echo -e "\n${YELLOW}确认以上信息正确？按回车继续，按 Ctrl+C 退出...${NC}"
read -r

# 2. 自动修改项目中的版本号和相关文件
echo -e "\n${CYAN}[1/6] 自动修改项目版本号与文档...${NC}"

# 修改 pubspec.yaml
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' "s/^version: .*/version: ${FULL_VERSION}/" pubspec.yaml
else
  sed -i "s/^version: .*/version: ${FULL_VERSION}/" pubspec.yaml
fi
echo -e "  ✔ 已更新 pubspec.yaml 版本为 ${FULL_VERSION}"

# 修改 lib/core/app_version.dart —— 应用内版本单一来源
# (设置页「关于」徽标与启动页 GitHub Release 升级检测都读这里;
#  这里必须与 pubspec 同步,否则新版装上后还会提示自己升级)
VERSION_FILE="lib/core/app_version.dart"
if [ -f "$VERSION_FILE" ]; then
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/^const String kAppVersion = .*/const String kAppVersion = '${NEW_VERSION}';/" "$VERSION_FILE"
    sed -i '' "s/^const String kAppBuild = .*/const String kAppBuild = '${BUILD_NUMBER}';/" "$VERSION_FILE"
  else
    sed -i "s/^const String kAppVersion = .*/const String kAppVersion = '${NEW_VERSION}';/" "$VERSION_FILE"
    sed -i "s/^const String kAppBuild = .*/const String kAppBuild = '${BUILD_NUMBER}';/" "$VERSION_FILE"
  fi
  # 校验:替换必须真的生效,防止 sed 失配悄悄发出旧版本号的包
  if ! grep -q "kAppVersion = '${NEW_VERSION}'" "$VERSION_FILE"; then
    echo -e "${RED}  ✘ ${VERSION_FILE} 版本号更新失败,请检查文件格式!${NC}"
    exit 1
  fi
  echo -e "  ✔ 已更新 ${VERSION_FILE} 为 ${NEW_VERSION}+${BUILD_NUMBER}(升级检测/关于页数据源)"
else
  echo -e "${RED}  ✘ 未找到 ${VERSION_FILE}(升级检测依赖它),中止发布!${NC}"
  exit 1
fi

# 修改 README.md 下载链接与标题版本
for README_FILE in README.md README_ZH.md; do
  if [ -f "$README_FILE" ]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "s/Release (v[0-9]\.[0-9]\.[0-9])/Release (${TAG_NAME})/g" "$README_FILE"
      sed -i '' "s/Termora-v[0-9]\.[0-9]\.[0-9]-macOS\.dmg/${DMG_NAME}/g" "$README_FILE"
      sed -i '' "s|releases/download/v[0-9]\.[0-9]\.[0-9]/|releases/download/${TAG_NAME}/|g" "$README_FILE"
    else
      sed -i "s/Release (v[0-9]\.[0-9]\.[0-9])/Release (${TAG_NAME})/g" "$README_FILE"
      sed -i "s/Termora-v[0-9]\.[0-9]\.[0-9]-macOS\.dmg/${DMG_NAME}/g" "$README_FILE"
      sed -i "s|releases/download/v[0-9]\.[0-9]\.[0-9]/|releases/download/${TAG_NAME}/|g" "$README_FILE"
    fi
    echo -e "  ✔ 已同步更新 ${README_FILE} 中的下载链接至 ${TAG_NAME}"
  fi
done

# 3. 静态检查 & macOS Release 编译
echo -e "\n${CYAN}[2/6] 执行编译打包 macOS Release 应用...${NC}"
flutter build macos --release

# 4. 生成 DMG 镜像包
echo -e "\n${CYAN}[3/6] 制作 macOS DMG 镜像安装包...${NC}"
DMG_DIR="build/dmg_tmp"
DMG_OUTPUT="build/${DMG_NAME}"
rm -rf "${DMG_DIR}"
mkdir -p "${DMG_DIR}"
cp -R "build/macos/Build/Products/Release/termora.app" "${DMG_DIR}/"
ln -s /Applications "${DMG_DIR}/Applications"
rm -f "${DMG_OUTPUT}"

hdiutil create -volname "Termora ${TAG_NAME}" -srcfolder "${DMG_DIR}" -ov -format UDZO "${DMG_OUTPUT}" > /dev/null

if [ -f "${DMG_OUTPUT}" ]; then
  FILE_SIZE=$(ls -lh "${DMG_OUTPUT}" | awk '{print $5}')
  echo -e "${GREEN}  ✔ DMG 安装包制作成功: ${DMG_OUTPUT} (大小: ${FILE_SIZE})${NC}"
else
  echo -e "${RED}  ✘ DMG 制作失败!${NC}"
  exit 1
fi

# 5. Git 提交 & 打 Tag 并推送
echo -e "\n${CYAN}[4/6] 提交 Git 变更并创建 Tag ${TAG_NAME}...${NC}"
git add .
git commit -m "chore(release): release ${TAG_NAME}" || echo "提示: 当前无额外代码修改，直接处理发布"
git push origin main

echo -e "  ✔ 创建并推送 Tag ${TAG_NAME}"
git tag -f -a "${TAG_NAME}" -m "Release ${TAG_NAME}"
git push -f origin "${TAG_NAME}"

# 6. 上传安装包至 GitHub Release
echo -e "\n${CYAN}[5/6] 创建 GitHub Release 并上传安装包...${NC}"

# 优先探测是否安装 gh cli
if command -v gh &> /dev/null; then
  echo -e "  👉 使用 GitHub CLI (gh) 创建 Release..."
  RELEASE_NOTES="### 🚀 Termora ${TAG_NAME} Release\n\n#### 📥 下载与安装\n- **macOS 安装包**: 下载下方 \`${DMG_NAME}\`\n- 打开后将 **Termora.app** 拖入 \`/Applications\` 文件夹即可。\n- 已安装旧版本的用户:启动 Termora 会自动检测到本次更新,点「立即升级」即可原地升级并重启。"
  gh release create "${TAG_NAME}" "${DMG_OUTPUT}" --title "Termora ${TAG_NAME} Release" --notes "${RELEASE_NOTES}" --target main
  echo -e "${GREEN}  ✔ 通过 gh cli 发布成功！${NC}"
else
  # 使用 REST API 和 GITHUB_TOKEN
  # 自动尝试读取 GitHub Token（检查环境变量或提示输入）
  GH_TOKEN="${GITHUB_TOKEN:-}"
  if [ -z "$GH_TOKEN" ]; then
    echo -e "${YELLOW}未检测到 gh CLI，也未设置 GITHUB_TOKEN 环境变量。${NC}"
    read -sp "请临时粘贴输入你的 GitHub Personal Access Token (输入时无回显，按回车确认，留空则跳过在线发布): " GH_TOKEN
    echo ""
  fi

  if [ -n "$GH_TOKEN" ]; then
    REPO_OWNER=$(git remote get-url origin | sed -n 's/.*github.com[:\/]\([^\/]*\)\/\([^\.]*\).*/\1/p')
    REPO_NAME=$(git remote get-url origin | sed -n 's/.*github.com[:\/]\([^\/]*\)\/\([^\.]*\).*/\2/p')

    echo -e "  👉 创建 Release 记录..."
    CREATE_RESP=$(curl -s -X POST -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases" \
      -d "{\"tag_name\":\"${TAG_NAME}\",\"target_commitish\":\"main\",\"name\":\"Termora ${TAG_NAME} Release\",\"body\":\"### 🚀 Termora ${TAG_NAME} Release\\n\\n#### 📥 下载与安装 (macOS)\\n下载下面的 \`${DMG_NAME}\` 并打开，拖入 Applications 文件夹即可安装。\\n已安装旧版本的用户：启动 Termora 会自动检测到本次更新，点「立即升级」即可原地升级并重启。\"}")

    RELEASE_ID=$(echo "$CREATE_RESP" | grep -m 1 '"id":' | sed 's/[^0-9]//g')
    if [ -n "$RELEASE_ID" ]; then
      echo -e "  ✔ Release 创建成功 (ID: ${RELEASE_ID})"
      echo -e "  👉 正在上传 ${DMG_NAME} 到 GitHub Assets..."
      curl -s -X POST -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GH_TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "Content-Type: application/octet-stream" \
        --data-binary @"${DMG_OUTPUT}" \
        "https://uploads.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/${RELEASE_ID}/assets?name=${DMG_NAME}" > /dev/null
      echo -e "${GREEN}  ✔ DMG 安装包上传完成！${NC}"

      # 同步更新主页 homepage
      curl -s -X PATCH -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GH_TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}" \
        -d "{\"homepage\":\"https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/tag/${TAG_NAME}\"}" > /dev/null
    else
      echo -e "${RED}  ✘ 创建 Release 失败，返回信息:${NC}\n$CREATE_RESP"
    fi
  else
    echo -e "${YELLOW}  👉 未提供 Token，已跳过在线 Release 创建（你可手动到 GitHub 上传 build/${DMG_NAME}）。${NC}"
  fi
fi

echo -e "\n${CYAN}[6/6] 全流程执行完毕！${NC}"
echo -e "${GREEN}======================================================================${NC}"
echo -e "${GREEN}   🎉 恭喜！Termora ${TAG_NAME} 版本已自动改版、打包 DMG 并顺利发布！   ${NC}"
echo -e "${GREEN}   🔗 访问发布主页: https://github.com/pynets/termora/releases       ${NC}"
echo -e "${GREEN}======================================================================${NC}"
