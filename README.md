# VPS Monitor - Netdata + 3X-UI + RKN Checker

## Что устанавливается

1. **Netdata** — мониторинг системы (CPU, RAM, сеть, диск, процессы)
2. **3X-UI плагин** — трафик и статус клиентов из панели 3X-UI
3. **VLESS/RKN Checker** — мониторинг доступности VLESS-порта, определение замедлений и блокировок

## Установка (одна команда на VPS)

```bash
# Скачать и запустить
curl -sL https://raw.githubusercontent.com/YOUR_REPO/install.sh | sudo bash

# Или если файл уже на VPS:
sudo bash install.sh
```

Скрипт спросит:
- URL панели 3X-UI (по умолчанию https://127.0.0.1:20028)
- Sub-path панели (например /bZ9FbJRYYXox6vuz9k)
- Логин/пароль панели
- VLESS порт
- Порт Netdata (по умолчанию 19999)

## После установки

Открой в браузере (через VPN):
```
http://<IP-вашего-VPS>:19999
```

### Что увидишь в Netdata

**Системные метрики (из коробки):**
- CPU по ядрам
- RAM/Swap использование
- Скорость сети по интерфейсам
- Дисковая активность
- Процессы
- И ещё ~200 метрик

**Раздел 3xui:**
- Суммарный трафик (upload/download)
- Количество клиентов online/total
- Трафик по каждому клиенту

**Раздел vless_checker:**
- Задержка TCP-подключения к VLESS-порту
- Задержка TLS handshake
- Статус VLESS (up/down)
- Доступность доменов из VPS (Google, YouTube, Instagram, etc.)

### Как определяется замедление РКН

Checker каждые 5 минут:
1. Подключается к VLESS-порту — меряет TCP-задержку
2. Делает TLS handshake — меряет задержку
3. Сравнивает с историей — если задержка выросла в 3+ раза, алерт
4. Проверяет доступность популярных доменов с VPS
5. Пишет всё в лог и метрики для Netdata

Когда ТСПУ начинает замедлять VLESS:
- TCP-задержка резко растёт
- TLS handshake может таймаутить
- Это видно на графике в Netdata

## Управление

```bash
# Статус
systemctl status netdata
systemctl status vless-checker

# Логи checker
journalctl -u vless-checker -f

# Логи в файлах
ls /opt/vps-checker/logs/

# Перезапуск
systemctl restart netdata
systemctl restart vless-checker
```

## Добавление второго VPS

На втором VPS запусти тот же install.sh. Netdata Cloud позволяет
объединить несколько нод в один дашборд (опционально, бесплатно до 5 нод).

## Безопасность

- Netdata слушает только localhost и VPN-подсети (10.*, 172.16.*, 192.168.*)
- Пароль 3X-UI хранится в /etc/netdata/3xui-env.conf (chmod 600)
- Порт Netdata не открыт в файрволе наружу
