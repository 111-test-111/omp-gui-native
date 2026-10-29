# 公开源码说明

本仓库是 OMP GUI Native 的首次公开源码快照，不是签名、经 Apple 公证的安装包发布。当前没有本 fork 的二进制更新源；继承的发布脚本和自动更新入口仍然禁用。上游的版本标签、发布说明和安装包不属于本项目。

## 来源与提交历史

- OMP GUI Native 是 [Tivano](https://github.com/elijah7x/tivano) 的修改版，保留 Droppy Code 和 T3 Code 来源、作者与许可。
- 公开 `main` 以原始公开 fork 基线 [Tivano 1.1.7](https://github.com/elijah7x/tivano/commit/d13d131dde8a47e78c1dd833fa79b53d7ea2c8e6) 为祖先，随后是整理后的首次公开集成快照。原始上游历史不改作者、不改日期。
- 首次公开之前的本地开发提交归并为一个新的公开快照提交，使用实际整理时间和维护者的 GitHub noreply 身份；它不伪装成从零实现整个上游应用，也不重写原来的本地仓库。
- `upstream-main` 保留创建 GitHub fork 时的上游主分支。它用于识别来源，不是 OMP GUI 的功能或更新分支；请从本仓库 `main` 构建。
- 原本地工作树、未提交工作、检查点、其他任务分支和应用数据不随快照发布。继续公开开发时，建议重新克隆本仓库，避免误推旧的私人分支或历史。

[历史归档](archive/README.md)可能引用公开前的本地提交、任务目录和报告，相关对象不一定存在于公开历史中。机器用户名路径已匿名化；保留的测量结果不是本次重新运行的结果，路径替换也不是对旧产物哈希的重新认证。

## 认证归属

模型服务商、API Key、OAuth、MCP 和工作进程仍由外部 OMP 管理。GUI 另行管理用户主动连接的 GitHub token 和自己的浏览器数据，不能视为不接触凭据的应用。

GitHub 仓库功能可使用已有的 `gh auth login` 或用户自己的 PAT。公开源码不附带 Tivano 的 OAuth App client ID。需要设备码登录的分发者须注册并管理自己的 GitHub OAuth App、启用 device flow，并将真实的公开 client ID 写入主应用 Info.plist 的 `OMPGitHubOAuthClientID`。未配置时，现有门禁隐藏浏览器登录入口；不影响 CLI/PAT 连接，也不需要在源码中放置 client secret。

## 本地工具与下载隔离

主应用不为所有本地工具产物自动添加下载隔离标记；GUI 中已完成的浏览器下载显式保留网页下载隔离，CEF helper 仍开启自动隔离。此配置不关闭系统 Gatekeeper、签名校验或 Chromium sandbox，也不批量清除已有文件标记。更新后的策略须重新启动应用后生效。

## 验证与分发边界

使用 [本地开发](local-development.md)的 `make build` 编译未签名 Dev 应用，按 [验证规范](verification.md)选择相关检查。编译成功不代表签名安装、外部账号登录、完整 GUI 交互或所有历史验收已经通过。

首次公开时关闭仓库 GitHub Actions 执行，保留已检入的工作流供维护者审查；启用前应确认账号权限、密钥、签名和发布目的地。源码公开不授权复用上游账号、签名证书、更新服务或发布凭据。[打包契约](packaging.md)中的 Developer ID 前置条件继续适用，不改用 ad-hoc 签名绕过。

不要提交个人会话、浏览器 profile/Cookie、认证文件、私钥、运行日志中的秘密或生成的构建产物。问题报告中的诊断、截图和路径也须先检查敏感信息。

## 许可与署名

**Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app**

[LICENSE](../LICENSE)的 GNU AGPL v3.0 和附加署名／来源条款继续适用；保留 README、About 和源码中的必要署名。[商标政策](../TRADEMARK.md)不因开源获得额外授权。[第三方声明](../THIRD_PARTY_NOTICES.md)保留 T3 Code MIT 及其他组件、字体、图标和 Git logo 的各自许可。
