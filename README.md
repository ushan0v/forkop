# Podkop Plus

[![Star](https://img.shields.io/github/stars/ushan0v/podkop-plus?style=social)](https://github.com/ushan0v/podkop-plus/stargazers)
[![Releases](https://img.shields.io/github/v/release/ushan0v/podkop-plus?label=releases)](https://github.com/ushan0v/podkop-plus/releases)
[![Telegram](https://img.shields.io/badge/Telegram-@ushan0v-2CA5E0?logo=telegram&logoColor=white)](https://t.me/ushan0v)
[![Original](https://img.shields.io/badge/original-itdoginfo%2Fpodkop-blue)](https://github.com/itdoginfo/podkop)
[![podkop-evolution](https://img.shields.io/badge/podkop--evolution-yandexru45-blue)](https://github.com/yandexru45/podkop-evolution)
[![zapret-openwrt](https://img.shields.io/badge/zapret--openwrt-remittor-blue)](https://github.com/remittor/zapret-openwrt/releases)
[![ByeDPI-OpenWrt](https://img.shields.io/badge/ByeDPI--OpenWrt-DPITrickster-blue)](https://github.com/DPITrickster/ByeDPI-OpenWrt/releases)
[![sing-box-extended](https://img.shields.io/badge/sing--box--extended-shtorm--7-blue)](https://github.com/shtorm-7/sing-box-extended/releases)
[![awg-openwrt](https://img.shields.io/badge/awg--openwrt-Slava--Shchipunov-blue)](https://github.com/Slava-Shchipunov/awg-openwrt/releases)

<table>
  <tr>
    <td>
      <img height="320" alt="preview_sections" src="https://github.com/user-attachments/assets/006e737b-e755-4c3c-939d-ca1a828cf11a" />
    </td>
    <td>
      <img height="320" alt="preview_dashboard" src="https://github.com/user-attachments/assets/0bbab5b0-cc7f-4841-b459-9d6e0e263e18" />
    </td>
  </tr>
</table>

> **НЕ ПИШИТЕ** с проблемами Podkop Plus в официальный [Telegram-чат](https://t.me/itdogchat). Это независимый форк. Разработчики и участники оригинального чата не имеют отношения к этому проекту.
> * Нашли баг или есть проблема? Создайте [Issue](https://github.com/ushan0v/podkop-plus/issues) в этом репозитории.
> * Не хотите или не умеете создавать Issue? Можете попробовать постучаться в личку [@ushan0v](https://t.me/ushan0v).

### Установка

```sh
sh <(wget -O - https://raw.githubusercontent.com/ushan0v/podkop-plus/main/install.sh)
```

Установщик поддерживает опциональную установку дополнительных компонентов:

- [zapret-openwrt](https://github.com/remittor/zapret-openwrt/releases)
- [ByeDPI-OpenWrt](https://github.com/DPITrickster/ByeDPI-OpenWrt/releases)
- [sing-box-extended](https://github.com/shtorm-7/sing-box-extended/releases)
- [awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt/releases)

### Что нового в этом форке

- Добавлена поддержка подписок.
- Интеграция Zapret и ByeDPI как отдельного действия.
- Поддержка sing-box extended и транспорта XHTTP.
- Обновленный LuCI-интерфейс и расширенное управление секциями. 
- Возможность исключать серверы из URLTest по стране или названию.

### Подписки

- Работа с подписками адаптирована из [podkop-evolution](https://github.com/yandexru45/podkop-evolution) и значительно расширена. 
- Реализована поддержка основных форматов: sing-box json, uri/base64 списки, clash/mihomo
- Добавлено чтение метаданных подписки.
- Подписки поддерживают HWID авторизацию.
- Для расшифровки подписок в формате `happ://crypt` используйте сервис [leeeet.dev/happ-decryptor](https://leeeet.dev/happ-decryptor).
- Парсинг подписок с большим количеством серверов (+100) создает сильную нагрузку, что может привести к высоким задержкам запуска или зависаниям. 

### Секции

Podkop Plus расширяет набор условий, которые можно использовать в правилах:

- Домены (`domain_suffix`)
- IP-адреса (`ip_cidr`)
- Точный полный домен (`domain`)
- Ключевое слово домена (`domain_keyword`)
- Регулярное выражение домена (`domain_regex`)
- Исходные IP-адреса (`source_cidr`)
- Полностью маршрутизированные IP-адреса
- Встроенные наборы правил
- Наборы правил (домены)
- Наборы правил (домены и подсети)
- Списки доменов и IPs

Для `Исходные IP-адреса` и `Полностью маршрутизированные IP-адреса` можно не только вручную вводить IP-адреса, но и выбирать устройство в локальной сети из удобного списка с именами.

### Наборы правил

`Наборы правил (домены)` принимают sing-box списки в форматах `.srs` и `.json`. Можно указывать как локальные пути, так и удаленные ссылки. Такие списки добавляются только в конфигурацию sing-box.

`Наборы правил (домены и подсети)` принимают те же форматы, но дополнительно извлекают подсети и добавляют их в nftables. Это полезно для списков, где важны не только домены, но и IP-диапазоны. Извлечение подсетей требует дополнительной нагрузки на роутер, поэтому секции разделены.

### Списки доменов и IPs

Секция `Списки доменов и IPs` объединяет списки доменов и подсетей. Принимает локальные и удаленные `.lst` списки. Добавлена поддержка смешанных списков.

### Интеграция Zapret

Zapret доступен как действие отдельной секции. Используется [remittor/zapret-openwrt](https://github.com/remittor/zapret-openwrt/releases). Интеграция не конфликтует с отдельным полноценным пакетом zapret (`luci-app-zapret`).

Реализация: `sing-box` отбирает трафик секции и отправляет его в `direct` outbound с отдельным `routing_mark` -> `zapret` принимает помеченные пакеты из очереди и применяет выбранную стратегию DPI-обхода.

Для стратегии `zapret` намеренно запрещены:

- шаблоны и hostlist placeholders: **`<HOSTLIST>`**, **`<HOSTLIST_NOAUTO>`**;
- hostname/IP selectors внутри самой стратегии: **`--hostlist*`**, **`--hostlist-auto*`**, **`--ipset*`**;
- ручное управление очередью и fwmark: **`--qnum`**, **`--dpi-desync-fwmark`**;
- режимы, которые ломают lifecycle процесса: **`--daemon`**;
- режимы, которые не должны быть итоговой стратегией запуска: **`--dry-run`**, **`--version`**;
- внешние конфиги вида **`@file`** или **`$file`**, которые обходят встроенную валидацию и управление очередями.

### Интеграция ByeDPI

ByeDPI доступен как действие отдельной секции. Используется [DPITrickster/ByeDPI-OpenWrt](https://github.com/DPITrickster/ByeDPI-OpenWrt/releases). Процесс работает под управлением Podkop Plus.

Реализация: `sing-box` отбирает трафик секции и отправляет его в локальный SOCKS5 outbound -> `ciadpi` принимает соединение на `127.0.0.1:1080+` и применяет выбранную стратегию DPI-обхода.

Для стратегии `ByeDPI` намеренно запрещены:

- ручное назначение listen-адреса и порта: **`--ip`**, **`-i`**, **`--port`**, **`-p`**;
- прозрачный режим, несовместимый с SOCKS5-подключением: **`--transparent`**, **`-E`**;
- режимы, которые ломают lifecycle процесса: **`--daemon`**, **`-D`**;
- ручное управление pid-файлами: **`--pidfile`**, **`-w`**;
- режимы, которые выводят справку или версию и сразу завершают работу: **`--help`**, **`-h`**, **`--version`**, **`-v`**;
