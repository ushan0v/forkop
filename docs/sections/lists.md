# Встроенные списки

Готовые списки доменов и подсетей для поля **Встроенные списки**. Их раз в сутки собирает проект [forkop-lists](https://github.com/ushan0v/forkop-lists) из открытых источников.

## Регионы

| Список | Подсети | Что в нём |
| --- | :---: | --- |
| **RU Blocked (All)** | ✓ | всё из RKN и Geo, около 75 тысяч доменов |
| **RU Blocked (RKN)** | ✓ | то, что блокирует или замедляет РКН.
| **RU Blocked (Geo)** | ✓ | сервисы, которые сами закрыли доступ из России
| **RU Only** | | российские сервисы, которые не работают через VPN |
| **UA Blocked** | | сайты, заблокированные в Украине |

Блокировку РКН можно обойти через [WARP](/tunnels/warp) с российским адресом или обходом DPI. Геоблок обойдёт только сервер в другой стране. Поэтому RKN и Geo можно пустить разными путями.

RU Only ставьте в секцию **Bypass**, если роутер в России, или в секцию с российским VPN, если вы за границей.

## Что входит в RU Blocked

Эти списки входят в RU Blocked целиком, вместе с подсетями:

| Список | Входят целиком |
| --- | --- |
| **RU Blocked (RKN)** | YouTube, Discord, Facebook, Instagram, X (Twitter), Telegram, WhatsApp, Roblox |
| **RU Blocked (Geo)** | ChatGPT, Claude, Gemini, Spotify, Supercell, TikTok |
| **RU Blocked (All)** | все из RKN и Geo |

В одной секции с RU Blocked их выбрать нельзя, они там уже есть. Отдельно их берут, чтобы пустить другим путём секцией выше.

GitHub, Twitch, Cloudflare, Google Play, DigitalOcean, Hetzner и OVH в RU Blocked не входят целиком, только их отдельные заблокированные домены. Из списка AI в Geo входят только нейросети, закрытые для России.

## Сервисы

| Список | Подсети | Что в нём |
| --- | :---: | --- |
| **AI** | ✓ | ChatGPT, Claude, Gemini, Grok, Perplexity, Copilot, Cursor и другие нейросети |
| **ChatGPT** | | |
| **Claude** | ✓ | |
| **Cloudflare** | ✓ | все адреса Cloudflare, а с ними и все сайты за Cloudflare, российские тоже |
| **DigitalOcean** | ✓ | |
| **Discord** | ✓ | вместе с голосовыми серверами |
| **Facebook** | | Facebook и Messenger |
| **Gemini** | | Gemini, AI Studio, NotebookLM, Jules |
| **GitHub** | | |
| **Google Play** | | |
| **Hetzner** | ✓ | |
| **Instagram** | | Instagram и Threads |
| **OVH** | ✓ | |
| **Roblox** | ✓ | |
| **Spotify** | | |
| **Supercell** | | Brawl Stars, Clash of Clans, Clash Royale и другие игры Supercell |
| **Telegram** | ✓ | |
| **TikTok** | | |
| **Twitch** | | |
| **WhatsApp** | ✓ | с подсетями Meta, на которые идут звонки |
| **X (Twitter)** | ✓ | |
| **YouTube** | | |
| **Ads** | | реклама и трекеры HaGeZi Pro, для секции Block |

## Если сайта нет в списке

Впишите домен в **Домены и IP-адреса**, так быстрее, чем ждать обновления. Чтобы домен попал в список для всех, [предложите его в forkop-lists](https://github.com/ushan0v/forkop-lists/issues/new?template=1-add.yml).

## Обновление

Встроенные списки и наборы правил по ссылке ядро скачивает при запуске, по расписанию и по кнопке **Обновить списки** на дашборде. Расписание задают **Автообновление наборов правил** и **Период обновления списков** в настройках, по умолчанию раз в сутки.

Если GitHub открывается плохо, включите в настройках **Скачивать списки через секцию** и выберите секцию с рабочим подключением.
