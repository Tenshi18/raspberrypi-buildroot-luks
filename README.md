# LUKS Pre-Burn Encryption for Raspberry Pi 5 Buildroot images

Автоматизированное создание зашифрованных .img образов с уникальными LUKS keyfile **до** записи на SD-карту.

## Особенности

- **Pre-burn шифрование** — шифрование образа до записи на карту
- **Уникальные ключи** — каждый образ получает свой UUID-based keyfile
- **USB-ключ** — разблокировка rootfs через USB-накопитель с keyfile
- **Пакетная обработка** — создание множества образов за один запуск
- **Buildroot ready** — полная интеграция с Buildroot для Raspberry Pi 5

## Быстрый старт

### 1. Шифрование одного образа

```bash
# Генерирует уникальный keyfile и создаёт зашифрованный образ
sudo ./pre-burn-encrypt.sh buildroot.img encrypted.img
```

### 2. Пакетное создание образов

```bash
# Создаёт 10 образов с уникальными ключами
sudo ./batch-encrypt-images.sh buildroot.img 10

# Результат:
# encrypted/device_001.img, device_002.img, ...
# keys/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.lek, ...
# manifest.csv — соответствие образов и ключей
```

### 3. Подготовка USB-ключа

```bash
# Форматирование USB-накопителя
sudo mkfs.vfat -F 32 /dev/sdX1

# Копирование ключа
sudo mount /dev/sdX1 /mnt
sudo cp keys/xxxxxxxx.lek /mnt/
sudo umount /mnt
```

### 4. Запись образа на SD-карту

```bash
sudo dd if=encrypted/device_001.img of=/dev/sdY bs=4M status=progress
```

## Структура проекта

```
.
├── pre-burn-encrypt.sh              # Основной скрипт шифрования
├── batch-encrypt-images.sh          # Пакетная обработка
│
└── buildroot-external/              # BR2_EXTERNAL для Buildroot
    ├── external.desc                # Описание external tree
    ├── external.mk                  # Makefile расширений
    ├── Config.in                    # Меню конфигурации LUKS
    ├── pre-burn-encrypt.sh          # Копия скрипта для post-image
    │
    ├── configs/
    │   └── raspberrypi5_luks_defconfig  # Готовый defconfig
    │
    ├── scripts/
    │   ├── post-build.sh            # Pre-image подготовка rootfs
    │   └── post-image-encrypt.sh    # Автошифрование после сборки
    │
    └── board/raspberrypi5/
        ├── linux-luks.fragment      # Crypto-модули ядра
        └── rootfs-overlay/          # Файлы для rootfs
            ├── init                 # Initramfs init с LUKS
            ├── etc/init.d/S00cryptroot
            └── usr/bin/sdmluksunlock
```

## Интеграция с Buildroot

### Полная интеграция с BR2_EXTERNAL

Этот метод автоматически шифрует образ после каждой сборки Buildroot.

**1. Клонируйте Buildroot и настройте external tree:**

```bash
git clone https://github.com/buildroot/buildroot.git
cd buildroot

# Укажите путь к этому репозиторию как BR2_EXTERNAL
export BR2_EXTERNAL=/path/to/raspberrypi5-buildroot-luks/buildroot-external
```

**2. Загрузите defconfig:**

```bash
make raspberrypi5_luks_defconfig
```

**3. (Опционально) Настройте параметры шифрования:**

```bash
make menuconfig
# → External options → LUKS Disk Encryption
#   [*] Enable LUKS rootfs encryption
#   (aes) Encryption algorithm          # aes для Pi5, xchacha для Pi4
#   () Use existing keyfile             # оставить пустым для автогенерации
#   [ ] Keep original unencrypted image # Сохранять ли оригинальные незашифрованные образы
```

**4. Соберите:**

```bash
make
```

ИЛИ

```bash
make -j$(( $(nproc) / 2 ))
```

**5. Результат:**

```
output/images/
├── sdcard.img              # Зашифрованный образ (заменяет оригинал)
├── sdcard-encrypted.img    # Симлинк на зашифрованный
├── keys/
│   └── <uuid>.lek          # Уникальный keyfile
└── encryption-info.txt     # Инструкции по использованию
```

### Ручное шифрование (без автоматизации)

Если вы хотите шифровать образ вручную после сборки:

```bash
# 1. Соберите Buildroot обычным способом
cd /path/to/buildroot
make raspberrypi5_defconfig
make

# 2. Зашифруйте образ
sudo /path/to/pre-burn-encrypt.sh \
    output/images/sdcard.img \
    output/images/sdcard-encrypted.img
```

### Процесс сборки Buildroot

```mermaid
flowchart TD
    subgraph Buildroot
        A[make] --> B[Compile packages]
        B --> C[Create rootfs.ext4]
        C --> D[post-build.sh<br/>Configure LUKS scripts]
        D --> E[Create sdcard.img]
        E --> F[post-image.sh<br/>Raspberry Pi setup]
    end
    
    subgraph "LUKS Encryption"
        F --> G[post-image-encrypt.sh]
        G --> H{BR2_LUKS_ENCRYPT=y?}
        H -->|No| Done[sdcard.img<br/>unencrypted]
        H -->|Yes| I[Generate keyfile]
        I --> J[Encrypt rootfs]
        J --> K[sdcard.img<br/>encrypted]
        K --> L[Save keyfile<br/>to keys/]
    end
    
    style K fill:#c8e6c9,color:#000
    style L fill:#fff9c4,color:#000
```

### Опции Config.in

| Опция | Описание | Default |
|-------|----------|---------|
| `BR2_LUKS_ENCRYPT` | Включить шифрование | n |
| `BR2_LUKS_CRYPTO` | Алгоритм: `aes` или `xchacha` | aes |
| `BR2_LUKS_KEYDIR` | Директория для ключей | $(BINARIES_DIR)/keys |
| `BR2_LUKS_KEYFILE` | Использовать существующий ключ | (пусто) |
| `BR2_LUKS_KEEP_UNENCRYPTED` | Сохранить незашифрованную копию | n |

## Как это работает

### Процесс шифрования (pre-burn-encrypt.sh)

```mermaid
flowchart TD
    A[Input .img<br/>unencrypted] --> B[Mount via loop device]
    B --> C[Backup rootfs<br/>to temp directory]
    C --> D[Create LUKS2 container<br/>with keyfile]
    D --> E[Restore rootfs<br/>to encrypted container]
    E --> F[Update boot configuration<br/>cmdline.txt, crypttab, fstab]
    F --> G[Output .img<br/>encrypted]
    
    style A fill:#e1f5ff,color:#000
    style G fill:#c8e6c9,color:#000
    style D fill:#fff9c4,color:#000
```

### Процесс загрузки

```mermaid
flowchart TD
    Start[Boot loader<br/>RPi firmware] --> Init[Initramfs/init<br/>LUKS init]
    
    Init --> Check{Encrypted<br/>device<br/>configured?}
    Check -->|No| NormalBoot[Normal boot continues]
    Check -->|Yes| Wait[Wait for encrypted device]
    
    Wait --> TryUnlock{Try to unlock}
    
    TryUnlock --> USB[Scan USB for keyfile]
    TryUnlock --> Embedded[Try embedded keyfile]
    TryUnlock --> Passphrase[Prompt for passphrase]
    
    USB --> Unlock[cryptsetup luksOpen]
    Embedded --> Unlock
    Passphrase --> Unlock
    
    Unlock --> Success{Unlock<br/>successful?}
    Success -->|No| Rescue[Rescue shell]
    Success -->|Yes| Mount[Mount encrypted rootfs]
    
    Mount --> SwitchRoot[switch_root to /newroot]
    SwitchRoot --> NormalBoot
    
    style Start fill:#e1f5ff,color:#000
    style Unlock fill:#fff9c4,color:#000
    style NormalBoot fill:#c8e6c9,color:#000
    style Rescue fill:#ffcdd2,color:#000
```

## Сравнение с sdm

| Аспект | sdm (post-burn) | Этот проект (pre-burn) |
|--------|-----------------|------------------------|
| Когда шифруется | После записи, на загруженной системе | До записи, на хосте |
| Scratch-диск | Требуется | Не требуется |
| Интерактивность | Да (passphrase, initramfs) | Нет (полная автоматизация) |
| Пакетная обработка | Сложно | Да, из коробки |
| Base OS | RasPiOS (Debian) | Buildroot/любая |
| Уникальные ключи | Ручное создание | Автоматическая генерация |

## Опции командной строки

### pre-burn-encrypt.sh

```
--keyfile PATH      Использовать существующий keyfile
--keydir PATH       Директория для сохранения keyfile (default: ./keys)
--mapper NAME       Имя mapper'а (default: cryptroot)
--crypto TYPE       aes или xchacha (default: aes для Pi5)
--keep-passphrase   Также включить разблокировку паролем
--help              Справка
```

### batch-encrypt-images.sh

```
--prefix PREFIX     Префикс имён файлов (default: device_)
--output-dir DIR    Директория вывода (default: ./encrypted)
--key-dir DIR       Директория ключей (default: ./keys)
--manifest FILE     Файл манифеста (default: manifest.csv)
--parallel N        Количество параллельных задач
--crypto TYPE       aes или xchacha
--dry-run           Показать план без выполнения
```

## Требования

- Linux хост с root-правами
- Пакеты: `cryptsetup`, `parted`, `uuid`, `e2fsprogs`, `rsync`
- Для Buildroot: стандартные зависимости

```bash
# Debian/Ubuntu
sudo apt install cryptsetup parted uuid-runtime e2fsprogs rsync
```

## Безопасность

**Важно:**

1. **Храните keyfiles безопасно** — потеря ключа = потеря данных
2. **Создайте резервные копии** ключей в защищённом месте
3. **Не храните ключи вместе с образами** в production
4. **Используйте --keep-passphrase** для резервного способа разблокировки
5. **manifest.csv содержит чувствительную информацию** — защитите его

## Производительность шифрования

### Raspberry Pi 5 (AES-NI)
```
aes-xts-plain64:  ~1800 MiB/s шифрование, ~1900 MiB/s дешифрование
```

### Raspberry Pi 4 (без AES-NI)
```
xchacha20-adiantum: ~170 MiB/s шифрование, ~180 MiB/s дешифрование
aes-xts-plain64:    ~88 MiB/s шифрование, ~108 MiB/s дешифрование
```

Используйте `--crypto xchacha` для Pi4 и более ранних моделей.

## Лицензия

MIT License

## Благодарности

- [sdm](https://github.com/gitbls/sdm) — оригинальные скрипты шифрования для Raspberry Pi OS

