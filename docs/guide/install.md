# Установка и обновление

## Требования

- OpenWrt 24.10 или новее;
- от 128 МБ оперативной памяти, лучше 256 МБ;
- от 18 до 38 МБ свободной флеш-памяти, в зависимости от [сборки ядра](#сборки-ядра).

## Установка

Подключитесь к роутеру по SSH и выполните:

```sh
sh <(wget -O - https://raw.githubusercontent.com/ushan0v/forkop/main/install.sh)
```

Команда устанавливает или обновляет [Forkop](https://github.com/ushan0v/forkop) и [sing-box-forkop](https://github.com/ushan0v/sing-box-forkop). Если новая версия меняет формат настроек, Forkop переведёт их сам, а прежние сохранит в `/etc/config/forkop.<версия>-<дата>`.

Если установка не удалась, полный журнал лежит в `/tmp/forkop-install.log`.

## Сборки ядра

При первой установке установщик спросит, какую сборку ядра [sing-box-forkop](https://github.com/ushan0v/sing-box-forkop) поставить. При обновлении остаётся установленная.

| | tiny | base, рекомендуется | full |
| --- | :---: | :---: | :---: |
| VLESS, Trojan, Shadowsocks, SOCKS, HTTP | ✓ | ✓ | ✓ |
| Hysteria, Hysteria2, TUIC | ✓ | ✓ | ✓ |
| VMess, AnyTLS, TrustTunnel | | ✓ | ✓ |
| WireGuard, AmneziaWG, Cloudflare WARP | | ✓ | ✓ |
| OpenVPN | | ✓ | ✓ |
| Tailscale, OpenConnect | | | ✓ |
| NaiveProxy, mieru, Snell, SSH, ShadowTLS, Tor | | | ✓ |
| Пакет | ~9,5 МБ | ~12 МБ | ~23 МБ |
| Бинарник | ~26 МБ | ~34 МБ | ~61 МБ |
| Нужно свободной флеш-памяти | ~18 МБ | ~22 МБ | ~38 МБ |

Размеры даны для ARM64. Флеш-память роутера сжимает файлы, поэтому ядру вместе с Forkop нужно меньше места, чем весит бинарник. NaiveProxy есть в full не на всех процессорах.

Сменить сборку:

```sh
sh <(wget -O - https://raw.githubusercontent.com/ushan0v/forkop/main/install.sh) --variant
```

Ядро можно собрать и самому, только с нужными протоколами. Forkop подстроится под такую сборку и покажет на странице только то, что в ней есть. Как собрать, описано в разделе [Сборки](https://github.com/ushan0v/sing-box-forkop#сборки) README ядра.

## Удаление

```sh
sh <(wget -O - https://raw.githubusercontent.com/ushan0v/forkop/main/install.sh) --uninstall
```

Команда удаляет `forkop`, `luci-app-forkop`, `luci-i18n-forkop-ru`, ядро `sing-box-forkop` и зависимости, которые больше ничему не нужны, а вместе с ними кеш ядра и скачанный дашборд YACD.
