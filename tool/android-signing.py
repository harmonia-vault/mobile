#!/usr/bin/env python3
"""生成被 Git 忽略的本机 Release 签名，已有配置保持不变。"""

import os
from pathlib import Path
import secrets
import subprocess


def main() -> None:
    android = Path(__file__).resolve().parent.parent / "android"
    properties = android / "key.properties"
    keystore = android / "app" / "harmonia-local-release.jks"
    if properties.exists():
        print("复用已有本机 Release 签名配置。")
        return
    if keystore.exists():
        raise SystemExit("签名库已存在但缺少 key.properties；请恢复原配置，不覆盖签名库。")

    os.umask(0o077)
    password = secrets.token_hex(32)
    subprocess.run(
        [
            "keytool", "-genkeypair", "-noprompt", "-keystore", str(keystore),
            "-storetype", "PKCS12", "-alias", "harmonia-local-release",
            "-keyalg", "RSA", "-keysize", "3072", "-validity", "10000",
            "-dname", "CN=Harmonia Local Release",
            "-storepass:env", "HARMONIA_RELEASE_SIGNING_PASSWORD",
            "-keypass:env", "HARMONIA_RELEASE_SIGNING_PASSWORD",
        ],
        env={**os.environ, "HARMONIA_RELEASE_SIGNING_PASSWORD": password},
        check=True,
    )
    with properties.open("x", encoding="utf-8") as output:
        output.write(
            "storeFile=harmonia-local-release.jks\n"
            "keyAlias=harmonia-local-release\n"
            f"storePassword={password}\n"
            f"keyPassword={password}\n"
        )
    print("已生成本机 Release 签名；密钥和配置均不进入 Git。")


if __name__ == "__main__":
    main()
