# 发布流程

## 1. 打 tag

```bash
git tag v0.1.0
git push origin v0.1.0
```

推上 `v*` 形式的 tag 会触发 `.github/workflows/release.yml`，它会：

1. 切到带 macOS 26+ SDK 的 Xcode，打印 `xcodebuild -version` 和 `-showsdks`
2. 校验最高 macOS SDK ≥ 26.0，不满足直接报错并说明原因
3. 装 XcodeGen（runner 上没有才装）
4. 跑 `./scripts/build-release.sh` —— 和本地出包是同一套命令
5. 压成 `HexoMan-<版本>-macos.zip`（`zip -y` 保留符号链接和权限位）
6. 从两个 tag 之间取 commit 列表拼更新日志
7. 上传 zip 作为 workflow artifact，并创建 GitHub Release

## 2. 关于签名

`.app` 是 **ad-hoc 签名**（`CODE_SIGN_IDENTITY: "-"`），没有开发者证书，也没有做 Apple 公证。所以用户第一次打开一定会被 Gatekeeper 拦住，这不是 bug。绕过方法写在 Release body 和 README 里：

- 右键 → 打开 → 再点一次「打开」
- 或 `xattr -dr com.apple.quarantine /Applications/HexoMan.app`

## 3. 如果 CI 报 SDK 相关错误

`macos-15` 镜像的默认 Xcode 可能偏旧，workflow 会先打印可用 SDK 列表再判定。两条出路：

- 在仓库 Settings → Actions → Variables 里加一个 `XCODE_PATH` 变量，指向 runner 上某个 Xcode 26+ 的 `Xcode.app` 路径，workflow 会 `sudo xcode-select -s` 切过去
- 或把 `runs-on` 换成带足够新 Xcode 的镜像标签

两个 workflow 里都有这一步，能省掉大量「为什么突然编不过」的排查时间。

## 4. CI

`.github/workflows/ci.yml` 在 push 到 main 和提 PR 时跑，只做 `xcodegen generate` + Debug 编译，出问题会顺带把构建日志作为 artifact 传上来。它不签名、不出包。
