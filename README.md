# asdf-php

🚀 **Enhanced PHP plugin for asdf with zero-configuration, multi-platform, and multi-version support**

[![Build history](https://buildstats.info/github/chart/asdf-community/asdf-php?branch=master)](https://github.com/asdf-community/asdf-php/actions)

> **Major Update**: This plugin now features **automatic OpenSSL compatibility management**, **cross-platform support**, and **optimized extension configurations** for modern PHP development.

## ✨ Key Features

### 🌍 Multi-Platform Support
- **Apple Silicon (M1/M2/M3)**: Native ARM64 support
- **Linux x86_64/ARM64**: Full cross-platform compatibility
- **macOS Intel**: Continued support with Homebrew integration
- **Windows WSL**: Complete support for Windows development

### 🔐 Automatic OpenSSL Management
- **PHP 5.x**: Auto-compiles OpenSSL 1.0.2u
- **PHP 7.x - 8.0**: Auto-compiles OpenSSL 1.1.1w
- **PHP 8.1+**: Uses system OpenSSL (3.0 compatible)
- **Smart Caching**: Compiled OpenSSL is permanently cached

### 📦 Modern Extension Configuration
- **21 Best-Practice Extensions**: Curated for 2024 PHP development
- **Version-Specific Optimization**: Intelligent extension selection
- **Zero Configuration**: Works out-of-the-box with optimal settings

### ⚡ Development Optimized
- **Performance Tuned**: OPcache and optimization settings
- **Security Focused**: Default security configurations
- **Development Ready**: Pre-configured error reporting and debugging

## 🚀 Quick Start

### Installation
```bash
# Add the plugin
asdf plugin-add php https://github.com/asdf-community/asdf-php.git

# Install any PHP version with zero configuration
asdf install php 8.2.13
asdf install php 7.4.33
asdf install php 5.6.40

# Set your preferred version
asdf global php 8.2.13

# Verify installation
php --version
```

### What You Get Automatically
```bash
# Each installation includes 21 modern extensions:
# Core: bcmath, calendar, exif, fpm, mbstring, mysqlnd, opcache, pcntl, sockets, zip
# Database: curl, mysqli, pdo-mysql, pdo-pgsql
# Security: openssl, sodium (PHP 8+)
# International: intl, libzip
# Graphics: gd
# Modern: json, ffi (version-dependent)
# Additional: gmp (8.1+), mcrypt (5.x), mysqlnd-compression (7.1+)
```

## 📋 Supported Versions

| PHP Version | OpenSSL | Extensions | Status |
|-------------|----------|------------|--------|
| **5.6** | 1.0.2u (auto) | 21 extensions | ✅ Legacy Support |
| **7.4** | 1.1.1w (auto) | 21 extensions | ✅ Stable |
| **8.0** | 1.1.1w (auto) | 21 extensions | ✅ Modern |
| **8.1** | System OpenSSL | 21 extensions | ✅ Latest |
| **8.2** | System OpenSSL | 21 extensions | ✅ Latest |
| **8.3** | System OpenSSL | 21 extensions | ✅ Latest |

## 🔧 Advanced Usage

### Environment Variables (Optional)
```bash
# Custom configure options
export PHP_CONFIGURE_OPTIONS="--enable-debug"

# Exclude PEAR
export PHP_WITHOUT_PEAR=yes

# Exclude PostgreSQL
export PHP_WITHOUT_PDO_PGSQL=yes

# Disable PCRE JIT
export PHP_WITHOUT_PCRE_JIT=yes
```

### Installation Output Example
```
🚀 Installing PHP 7.4.33...
   Platform: Linux x86_64
🔍 Checking system compatibility...
✅ System compatibility: Linux x86_64
🔐 Setting up OpenSSL for PHP ...
   Required version: 1.1.1w
⏭️  Using cached OpenSSL: /home/user/.asdf/openssl/1.1.1w
📋 Extensions: --enable-bcmath --enable-calendar --enable-exif ...
🔧 Make flags: -j4
🔧 Running buildconf...
🔧 Running ./configure ...
🔧 Running make -j4...
🔧 Running make install...
📝 Created optimized php.ini: /home/user/.asdf/installs/php/7.4.33/conf.d/php.ini
✅ PHP 7.4.33 installed successfully!
   Binary: /home/user/.asdf/installs/php/7.4.33/bin/php
   Test: /home/user/.asdf/installs/php/7.4.33/bin/php --version
```

## 🏗️ System Requirements

### Dependencies (Auto-Checked)
- **Build Tools**: `curl`, `tar`, `make`, `gcc/clang`
- **macOS**: `brew` (for additional packages)
- **Linux**: Standard build tools

### Optional Extensions
```bash
# macOS - for additional image processing support
brew install gmp libsodium imagemagick

# Linux - distribution-specific packages
# Ubuntu/Debian:
sudo apt-get install libgmp-dev libsodium-dev libmagickwand-dev

# CentOS/RHEL:
sudo yum install gmp-devel libsodium-devel ImageMagick-devel
```

## 📚 Additional Extensions

While the plugin provides 21 essential extensions automatically, you can install additional ones via PECL:

```bash
# Install additional extensions
pecl install redis
pecl install imagick
pecl install xdebug

# Enable them
echo "extension=redis.so
extension=imagick.so
extension=xdebug.so" > $(asdf where php)/conf.d/99-custom.ini
```

## 🐳 Development Workflow

### Global Composer
```bash
# Composer is installed automatically
composer global require friendsofphp/php-cs-fixer
asdf reshim
php-cs-fixer --version
```

### Project-Specific Versions
```bash
# Set project PHP version
asdf local php 8.1.25

# Install project dependencies
composer install

# Run your application
php artisan serve  # Laravel
php -S localhost:8000  # Built-in server
```

## 🔍 Troubleshooting

### Common Issues

#### OpenSSL Compilation
```bash
# Clear cache and reinstall
rm -rf ~/.asdf/openssl/
asdf install php <version>
```

#### Extension Issues
```bash
# Check available extensions
php -m

# Check PHP configuration
php --ini
```

#### Platform-Specific Issues
The plugin automatically detects and handles platform-specific requirements. Check the installation output for compatibility information.

### Getting Help
This plugin is designed to work out-of-the-box with zero configuration. If you encounter issues:

1. Check that you have the required build tools installed
2. Ensure your system meets the prerequisites listed above
3. Review the installation output for any error messages
4. Check the [GitHub Issues](https://github.com/asdf-community/asdf-php/issues) for known problems

## 🤝 Contributing

This plugin is actively maintained and improved. We welcome contributions!

### Development Setup
```bash
# Clone the repository
git clone https://github.com/asdf-community/asdf-php.git
cd asdf-php

# Test changes
bash bin/install --help
```

### What We've Improved
- ✅ **Zero Configuration**: Works out-of-the-box
- ✅ **Multi-Platform**: macOS, Linux, ARM64, x86_64 support
- ✅ **OpenSSL Compatibility**: Automatic version management
- ✅ **Modern Extensions**: 2024 best practices
- ✅ **Performance Optimized**: Parallel compilation and caching

## 📄 License

Licensed under the [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0).

## 🙏 Acknowledgments

- Original version created by [@Stratus3D](https://github.com/Stratus3D)
- Enhanced with modern PHP development practices
- Community contributions and feedback

---

**🎉 Enjoy seamless PHP development across all platforms and versions!**