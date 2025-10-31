# asdf-php

🚀 **Enhanced PHP plugin for asdf with zero-configuration, multi-platform support - optimized for PHP 7.x+**

[![Build history](https://buildstats.info/github/chart/asdf-community/asdf-php?branch=master)](https://github.com/asdf-community/asdf-php/actions)

> **⚠️ Important**: This plugin is primarily designed for **PHP 7.x and newer versions**. PHP 5.x versions have significant compatibility issues with modern systems and are **not recommended** for use.

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

### Installation (Recommended for PHP 7.x+)
```bash
# Add the plugin
asdf plugin-add php https://github.com/asdf-community/asdf-php.git

# Install modern PHP versions with zero configuration
asdf install php 8.2.13
asdf install php 8.1.25
asdf install php 7.4.33
asdf install php 7.4.30

# Set your preferred version
asdf global php 8.2.13

# Verify installation
php --version
```

### ⚠️ PHP 5.x Compatibility Notice
PHP 5.x versions (5.4, 5.5, 5.6) are **not recommended** due to:
- **Bison version conflicts**: Modern systems use Bison 3.x, but PHP 5.x requires Bison 2.x
- **Missing development headers**: libcurl, libxml2, and other dependencies may be missing
- **Deprecated extensions**: Many features have security vulnerabilities and are no longer maintained
- **Compilation failures**: High likelihood of build failures on modern systems

**Alternative for PHP 5.x**: Consider using Docker containers or older system environments.

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

### ✅ **Recommended Versions (Full Support)**

| PHP Version | OpenSSL | Extensions | Status | Notes |
|-------------|----------|------------|--------|-------|
| **8.3** | System OpenSSL | 22 extensions | ✅ Latest | Modern features, best performance |
| **8.2** | System OpenSSL | 22 extensions | ✅ Latest | FFI support, enum improvements |
| **8.1** | System OpenSSL | 22 extensions | ✅ Latest | Sodium, GMP support |
| **8.0** | 1.1.1w (auto) | 22 extensions | ✅ Modern | Last version before breaking changes |
| **7.4** | 1.1.1w (auto) | 22 extensions | ✅ Stable | Excellent compatibility, still maintained |

### ⚠️ **Legacy Versions (Limited Support)**

| PHP Version | OpenSSL | Extensions | Status | Compatibility Issues |
|-------------|----------|------------|--------|----------------------|
| **7.3** | 1.1.1w (auto) | 21 extensions | ⚠️ Limited | Intl extension skipped, freetype disabled |
| **7.2** | 1.1.1w (auto) | 21 extensions | ⚠️ Limited | Multiple extension compilation issues |
| **7.1** | 1.1.1w (auto) | 22 extensions | ⚠️ Limited | Minor compatibility issues |
| **7.0** | 1.1.1w (auto) | 22 extensions | ⚠️ Limited | End-of-life, security concerns |

### ❌ **Not Recommended (High Failure Rate)**

| PHP Version | OpenSSL | Extensions | Status | Known Issues |
|-------------|----------|------------|--------|-------------|
| **5.6** | 1.0.2u (auto) | 22 extensions | ❌ Not Recommended | Bison 3.x conflicts, missing dev headers |
| **5.5** | 1.0.2u (auto) | 22 extensions | ❌ Not Recommended | Same as 5.6, even worse compatibility |
| **5.4** | 1.0.2u (auto) | 22 extensions | ❌ Not Recommended | Bison 3.x conflicts, libcurl issues |

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

#### PHP 5.x Compilation Failures
```bash
# Symptoms:
# - "bison is required" errors (version too new)
# - "Please reinstall the libcurl distribution" errors
# - Various missing development header errors

# Solution: Use Docker for PHP 5.x
docker run --rm -it php:5.6-apache bash
# Or use an older system with compatible tool versions
```

#### PHP 7.x Extension Issues
```bash
# Check available extensions
php -m

# Check PHP configuration
php --ini

# GD extension without freetype (expected behavior for 7.3 and below)
php -r "if (function_exists('imagettftext')) echo 'TTF supported'; else echo 'TTF not available';"
```

#### OpenSSL Compilation
```bash
# Clear cache and reinstall
rm -rf ~/.asdf/openssl/
asdf install php <version>
```

#### Platform-Specific Issues
The plugin automatically detects and handles platform-specific requirements. Check the installation output for compatibility information.

### Version Recommendations

- **For new projects**: Use **PHP 8.1+** for latest features and security
- **For legacy projects**: Use **PHP 7.4** for excellent compatibility
- **For testing**: PHP 8.2+ for modern development
- **Avoid PHP 5.x**: High failure rate on modern systems

### Getting Help
This plugin is designed to work out-of-the-box with zero configuration for PHP 7.x+. If you encounter issues:

1. **Use PHP 7.4+** for the best experience
2. Check that you have the required build tools installed
3. Ensure your system meets the prerequisites listed above
4. Review the installation output for any error messages
5. Check the [GitHub Issues](https://github.com/asdf-community/asdf-php/issues) for known problems

**PHP 5.x Issues**: Due to incompatibility with modern systems, PHP 5.x issues are considered expected behavior and may not receive support.

## 🎯 Version Support Philosophy

### Primary Focus: PHP 7.x+
This plugin is designed and optimized for **PHP 7.4 and newer versions**, providing:
- ✅ **Reliable compilation** on modern systems
- ✅ **Complete extension support** with best practices
- ✅ **Security-focused configurations**
- ✅ **Zero-configuration experience**

### Legacy PHP 5.x Support
PHP 5.x support is provided on a **best-effort basis** but comes with significant limitations:
- ❌ **High compilation failure rate** on modern systems
- ❌ **Missing development tools** (Bison 3.x incompatibility)
- ❌ **Security vulnerabilities** (end-of-life versions)
- ❌ **Limited troubleshooting support**

### Recommended Approach
1. **New Projects**: Start with PHP 8.1+ for modern features
2. **Legacy Projects**: Upgrade to PHP 7.4+ if possible
3. **PHP 5.x Requirements**: Use Docker containers or dedicated environments

## 🤝 Contributing

This plugin is actively maintained and improved. We welcome contributions!

### Development Setup
```bash
# Clone your fork
git clone https://github.com/x-rush/asdf-php.git
cd asdf-php

# Test changes
bash bin/install --help
```

### What We've Improved
- ✅ **Zero Configuration**: Works out-of-the-box for PHP 7.x+
- ✅ **Multi-Platform**: macOS, Linux, ARM64, x86_64 support
- ✅ **OpenSSL Compatibility**: Automatic version management
- ✅ **Modern Extensions**: 2024 best practices
- ✅ **Performance Optimized**: Parallel compilation and caching
- ✅ **Realistic Expectations**: Clear version support guidance

## 📄 License

Licensed under the [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0).

## 🙏 Acknowledgments

- Original version created by [@Stratus3D](https://github.com/Stratus3D)
- Enhanced with modern PHP development practices
- Community contributions and feedback

---

**🎉 Enjoy seamless PHP development across all platforms and versions!**