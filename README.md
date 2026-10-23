# 3xui_noAD

基于 **MHSanaei/3x-ui v3.9.0** 的非官方去广告衍生版本。保留上游署名和 GPL-3.0 许可证，不代表上游官方发行或背书。

## 来源与引用

- 上游项目：[MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui)。原作者及贡献者拥有各自代码的著作权，本仓库仅对去广告修改负责。
- 基础版本：[v3.9.0](https://github.com/MHSanaei/3x-ui/releases/tag/v3.9.0)。对应源码提交：[`3cd4bf504c3cd8ea9b1c1fdb032a9796c5c43ddb`](https://github.com/MHSanaei/3x-ui/commit/3cd4bf504c3cd8ea9b1c1fdb032a9796c5c43ddb)。
- 上游完整说明保存在 [README.upstream.md](README.upstream.md)，其他上游语言文档和版权信息保留。
- 上游文档：[docs.sanaei.dev](https://docs.sanaei.dev)。代理核心：[XTLS/Xray-core](https://github.com/XTLS/Xray-core)。
- 许可证：[GNU GPL v3](LICENSE)。本仓库修改及对应二进制继续按 GPL-3.0 分发；发布源码与构建脚本供获取对应源码和自行构建。

## 修改说明

修改日期：**2026-10-23**。本次发行标识：**3.9.0-noad.1**。

1. 后台赞助接口固定返回 `{"sponsors":[]}`，不再获取、缓存或回退使用远程广告列表。
2. 广告图片接口固定返回不可用，不再代理获取广告图片。
3. 前端 `SponsorSlot` 固定不渲染，覆盖登录页、仪表盘及侧栏等广告位，也不读取旧的广告查询缓存。
4. 增加后台无广告响应/网络访问/图片拒绝测试和前端不渲染测试。
5. 保留 API 数据结构与路由，避免影响面板其他功能；不移除上游署名、许可证或正常项目链接。
6. 不修改代理协议、路由、流量统计、订阅、账户或数据库结构。除版本标识外，不进行功能扩展。

上游原始工作流保存在 `.github/upstream-workflows/`，仅用于追溯，不会自动执行。实际构建发布入口为 `.github/workflows/noad-release.yml`，避免意外部署上游文档站、发布 Docker 镜像或调用上游专用服务。

## 命令行中文化

当前分支已将管理菜单、安装和更新脚本、证书与数据库管理、主程序参数帮助及操作结果提示改为简体中文。中文化修改仅在源码仓库及后续构建中生效，**不会覆盖已经发布的 `v3.9.0-noad.1` Release 文件，也不会自动部署到服务器**。原始上游引用、署名及许可证继续保留。

- 命令名、参数、环境变量及 `y/n`、`t/g` 等输入值不变，中文提示说明对应含义和默认值。
- `hasDefaultCredential:`、`port:`、`webBasePath:`、`cert:`、`key:`、`listenIP:`、`apiToken:` 等输出字段供脚本解析，保留原始拼写和布尔值；更新状态 JSON 与安装结果环境文件格式也保持不变。
- 第三方程序（例如系统包管理器、acme.sh、Xray）的原生日志，以及封禁日志协议字段，不强制翻译；本次不修改网页语言设置或服务端业务日志体系。
- 安装和更新脚本仍指向上游发行渠道，并非本衍生版的一键安装器；运行官方安装、更新或菜单更新可能覆盖去广告及中文化修改。
- 后续完整包包含同一提交的中文管理菜单；仅面板包仍只提供面板程序，不替换已安装的管理菜单。构建来源以包内 `NOAD_BUILD.json` 的提交记录为准。

回归检查不执行安装器或更新器的实际入口，只提取无副作用的函数验证菜单、确认输入、非交互默认值和更新状态格式；指定编译后的面板程序时，还会在临时数据库目录验证帮助及固定输出字段：

```bash
python3 -m pip install tree-sitter==0.26.0 tree-sitter-bash==0.25.1
python3 scripts/test-cli-zh.py
python3 scripts/test-cli-zh.py --binary /path/to/x-ui-noad
```

## 下载与校验

从本仓库 [Releases](https://github.com/GG-bonded/3xui_noAD/releases) 获取产物，**不要使用上游一键安装命令来安装此衍生版**。

- `x-ui-linux-amd64-noad.tar.gz`：Linux amd64 完整包，以官方 v3.9.0 安装包为基础，替换去广告面板主程序并补充许可证、来源和修改说明；中文化提交后的构建还包含中文管理菜单，既有 Release 保持不变。
- `x-ui-panel-linux-amd64-noad.tar.gz`：仅面板主程序，供已经安装 v3.9.0 的 Linux amd64 环境做最小替换；不包含 Xray 或 geodata。
- `3xui-noad-source.tar.gz`：对应发行提交的完整源码和构建脚本，不包含私有运行数据。
- `SHA256SUMS`：以上文件的 SHA-256 校验值。

```bash
# 在下载的文件所在目录校验完整性。
sha256sum -c SHA256SUMS --ignore-missing
```

仅提供 **Linux amd64/x86_64** 已构建产物，不声称其他架构经过验证。完整包中的第三方程序与数据沿用其各自许可证。

## 构建与测试

使用 `go.mod` 指定的 Go 工具链、`.nvmrc` 指定的 Node.js 主版本和 npm 11 以上。Linux 静态 amd64 构建还需要 `musl-gcc`。

```bash
# 构建前端，Go 编译时会嵌入该输出。
cd frontend
npm ci
npm run typecheck
npm test -- src/test/sponsors.test.tsx src/test/sponsor-slot-noad.test.tsx
npm run build
cd ..

# 对受影响的后台模块执行测试，再构建静态面板程序。
export CGO_ENABLED=1 CC=musl-gcc
go test ./internal/config ./internal/web/service/panel ./internal/web/controller
go build -trimpath -buildvcs=true -ldflags="-s -w -linkmode external -extldflags '-static'" -o x-ui-noad .
```

官方基础安装包固定为 v3.9.0，打包脚本验证其 SHA-256 为 `d7cbe0bf6358ee0d2117c24fd2efb483502e411d38e2ea59bd0bf5e7a3e39390`。工作流生成新的衍生版校验文件，不复用上游包的摘要作为修改后产物的摘要。

## 安装与回滚注意

- 安装前备份原程序、数据库和配置。已有同版本安装优先仅替换面板程序，不覆盖自定义 Xray、geodata、证书或服务配置。
- 替换程序需要短暂停止并重新启动 `x-ui` 服务，代理连接可能受到短暂影响。
- 包内仍包含上游管理脚本；其更新功能指向上游，使用后会恢复官方版本及广告。该衍生版不提供自动更新劫持。
- 浏览器旧标签页可能仍驻留旧脚本，部署后应重新载入；必要时使用强制刷新。
- 本仓库不包含任何 VPS 私钥、管理员密码、订阅身份、实际数据库或部署备份。
- 本项目沿用上游安全和使用限制，不应将管理面板不加防护地暴露到公网。
