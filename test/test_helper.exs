System.put_env("GIT_CONFIG_COUNT", "1")
System.put_env("GIT_CONFIG_KEY_0", "commit.gpgsign")
System.put_env("GIT_CONFIG_VALUE_0", "false")

ExUnit.start()
