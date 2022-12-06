import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_sodium/flutter_sodium.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photos/core/constants.dart';
// ignore: import_of_legacy_library_into_null_safe
import 'package:photos/core/error-reporting/super_logging.dart';
import 'package:photos/core/errors.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/db/collections_db.dart';
// ignore: import_of_legacy_library_into_null_safe
import 'package:photos/db/files_db.dart';
// ignore: import_of_legacy_library_into_null_safe
import 'package:photos/db/ignored_files_db.dart';
// ignore: import_of_legacy_library_into_null_safe
import 'package:photos/db/memories_db.dart';
import 'package:photos/db/public_keys_db.dart';
// ignore: import_of_legacy_library_into_null_safe
import 'package:photos/db/trash_db.dart';
import 'package:photos/db/upload_locks_db.dart';
import 'package:photos/events/signed_in_event.dart';
import 'package:photos/events/user_logged_out_event.dart';
import 'package:photos/models/key_attributes.dart';
import 'package:photos/models/key_gen_result.dart';
import 'package:photos/models/private_key_attributes.dart';
// ignore: import_of_legacy_library_into_null_safe
import 'package:photos/services/billing_service.dart';
// ignore: import_of_legacy_library_into_null_safe
import 'package:photos/services/collections_service.dart';
// ignore: import_of_legacy_library_into_null_safe
import 'package:photos/services/favorites_service.dart';
// ignore: import_of_legacy_library_into_null_safe
import 'package:photos/services/memories_service.dart';
// ignore: import_of_legacy_library_into_null_safe
import 'package:photos/services/search_service.dart';
// ignore: import_of_legacy_library_into_null_safe
import 'package:photos/services/sync_service.dart';
import 'package:photos/utils/crypto_util.dart';
import 'package:photos/utils/validator_util.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:wakelock/wakelock.dart';

class Configuration {
  Configuration._privateConstructor();

  static final Configuration instance = Configuration._privateConstructor();
  static const endpoint = String.fromEnvironment(
    "endpoint",
    defaultValue: kDefaultProductionEndpoint,
  );
  static const emailKey = "email";
  static const foldersToBackUpKey = "folders_to_back_up";
  static const keyAttributesKey = "key_attributes";
  static const keyKey = "key";
  static const keyShouldBackupOverMobileData = "should_backup_over_mobile_data";
  static const keyAlbumGridSize = "album_grid_size";
  static const keyShouldBackupVideos = "should_backup_videos";

  // keyShouldKeepDeviceAwake is used to determine whether the device screen
  // should be kept on while the app is in foreground.
  static const keyShouldKeepDeviceAwake = "should_keep_device_awake";
  static const keyShouldHideFromRecents = "should_hide_from_recents";
  static const keyShouldShowLockScreen = "should_show_lock_screen";
  static const keyHasSelectedAnyBackupFolder =
      "has_selected_any_folder_for_backup";
  static const lastTempFolderClearTimeKey = "last_temp_folder_clear_time";
  static const nameKey = "name";
  static const secretKeyKey = "secret_key";
  static const tokenKey = "token";
  static const encryptedTokenKey = "encrypted_token";
  static const userIDKey = "user_id";
  static const hasMigratedSecureStorageToFirstUnlockKey =
      "has_migrated_secure_storage_to_first_unlock";
  static const hasSelectedAllFoldersForBackupKey =
      "has_selected_all_folders_for_backup";
  static const anonymousUserIDKey = "anonymous_user_id";

  final kTempFolderDeletionTimeBuffer = const Duration(days: 1).inMicroseconds;

  static final _logger = Logger("Configuration");

  String? _cachedToken;
  late String _documentsDirectory;
  String? _key;
  late SharedPreferences _preferences;
  String? _secretKey;
  late FlutterSecureStorage _secureStorage;
  late String _tempDirectory;
  late String _thumbnailCacheDirectory;
  // 6th July 22: Remove this after 3 months. Hopefully, active users
  // will migrate to newer version of the app, where shared media is stored
  // on appSupport directory which OS won't clean up automatically
  late String _sharedTempMediaDirectory;

  late String _sharedDocumentsMediaDirectory;
  String? _volatilePassword;

  final _secureStorageOptionsIOS =
      const IOSOptions(accessibility: IOSAccessibility.first_unlock);

  Future<void> init() async {
    _preferences = await SharedPreferences.getInstance();
    _secureStorage = const FlutterSecureStorage();
    _documentsDirectory = (await getApplicationDocumentsDirectory()).path;
    _tempDirectory = _documentsDirectory + "/temp/";
    final tempDirectory = io.Directory(_tempDirectory);
    try {
      final currentTime = DateTime.now().microsecondsSinceEpoch;
      if (tempDirectory.existsSync() &&
          (_preferences.getInt(lastTempFolderClearTimeKey) ?? 0) <
              (currentTime - kTempFolderDeletionTimeBuffer)) {
        await tempDirectory.delete(recursive: true);
        await _preferences.setInt(lastTempFolderClearTimeKey, currentTime);
        _logger.info("Cleared temp folder");
      } else {
        _logger.info("Skipping temp folder clear");
      }
    } catch (e) {
      _logger.warning(e);
    }
    tempDirectory.createSync(recursive: true);
    final tempDirectoryPath = (await getTemporaryDirectory()).path;
    _thumbnailCacheDirectory = tempDirectoryPath + "/thumbnail-cache";
    io.Directory(_thumbnailCacheDirectory).createSync(recursive: true);
    _sharedTempMediaDirectory = tempDirectoryPath + "/ente-shared-media";
    io.Directory(_sharedTempMediaDirectory).createSync(recursive: true);
    _sharedDocumentsMediaDirectory = _documentsDirectory + "/ente-shared-media";
    io.Directory(_sharedDocumentsMediaDirectory).createSync(recursive: true);
    if (!_preferences.containsKey(tokenKey)) {
      await _secureStorage.deleteAll(iOptions: _secureStorageOptionsIOS);
    } else {
      _key = await _secureStorage.read(
        key: keyKey,
        iOptions: _secureStorageOptionsIOS,
      );
      _secretKey = await _secureStorage.read(
        key: secretKeyKey,
        iOptions: _secureStorageOptionsIOS,
      );
      if (_key == null) {
        await logout(autoLogout: true);
      }
      await _migrateSecurityStorageToFirstUnlock();
    }
    SuperLogging.setUserID(await _getOrCreateAnonymousUserID());
  }

  Future<void> logout({bool autoLogout = false}) async {
    if (SyncService.instance.isSyncInProgress()) {
      SyncService.instance.stopSync();
      try {
        await SyncService.instance
            .existingSync()
            .timeout(const Duration(seconds: 5));
      } catch (e) {
        // ignore
      }
    }
    await _preferences.clear();
    await _secureStorage.deleteAll(iOptions: _secureStorageOptionsIOS);
    _key = null;
    _cachedToken = null;
    _secretKey = null;
    await FilesDB.instance.clearTable();
    await CollectionsDB.instance.clearTable();
    await MemoriesDB.instance.clearTable();
    await PublicKeysDB.instance.clearTable();
    await UploadLocksDB.instance.clearTable();
    await IgnoredFilesDB.instance.clearTable();
    await TrashDB.instance.clearTable();
    if (!autoLogout) {
      CollectionsService.instance.clearCache();
      FavoritesService.instance.clearCache();
      MemoriesService.instance.clearCache();
      BillingService.instance.clearCache();
      SearchService.instance.clearCache();
      Bus.instance.fire(UserLoggedOutEvent());
    } else {
      _preferences.setBool("auto_logout", true);
    }
  }

  bool showAutoLogoutDialog() {
    return _preferences.containsKey("auto_logout");
  }

  Future<bool> clearAutoLogoutFlag() {
    return _preferences.remove("auto_logout");
  }

  Future<KeyGenResult> generateKey(String password) async {
    // Create a master key
    final masterKey = CryptoUtil.generateKey();

    // Create a recovery key
    final recoveryKey = CryptoUtil.generateKey();

    // Encrypt master key and recovery key with each other
    final encryptedMasterKey = CryptoUtil.encryptSync(masterKey, recoveryKey);
    final encryptedRecoveryKey = CryptoUtil.encryptSync(recoveryKey, masterKey);

    // Derive a key from the password that will be used to encrypt and
    // decrypt the master key
    final kekSalt = CryptoUtil.getSaltToDeriveKey();
    final derivedKeyResult = await CryptoUtil.deriveSensitiveKey(
      utf8.encode(password) as Uint8List,
      kekSalt,
    );

    // Encrypt the key with this derived key
    final encryptedKeyData =
        CryptoUtil.encryptSync(masterKey, derivedKeyResult.key);

    // Generate a public-private keypair and encrypt the latter
    final keyPair = await CryptoUtil.generateKeyPair();
    final encryptedSecretKeyData =
        CryptoUtil.encryptSync(keyPair.sk, masterKey);

    final attributes = KeyAttributes(
      Sodium.bin2base64(kekSalt),
      Sodium.bin2base64(encryptedKeyData.encryptedData!),
      Sodium.bin2base64(encryptedKeyData.nonce!),
      Sodium.bin2base64(keyPair.pk),
      Sodium.bin2base64(encryptedSecretKeyData.encryptedData!),
      Sodium.bin2base64(encryptedSecretKeyData.nonce!),
      derivedKeyResult.memLimit,
      derivedKeyResult.opsLimit,
      Sodium.bin2base64(encryptedMasterKey.encryptedData!),
      Sodium.bin2base64(encryptedMasterKey.nonce!),
      Sodium.bin2base64(encryptedRecoveryKey.encryptedData!),
      Sodium.bin2base64(encryptedRecoveryKey.nonce!),
    );
    final privateAttributes = PrivateKeyAttributes(
      Sodium.bin2base64(masterKey),
      Sodium.bin2hex(recoveryKey),
      Sodium.bin2base64(keyPair.sk),
    );
    return KeyGenResult(attributes, privateAttributes);
  }

  Future<KeyAttributes> updatePassword(String password) async {
    // Get master key
    final masterKey = getKey();

    // Derive a key from the password that will be used to encrypt and
    // decrypt the master key
    final kekSalt = CryptoUtil.getSaltToDeriveKey();
    final derivedKeyResult = await CryptoUtil.deriveSensitiveKey(
      utf8.encode(password) as Uint8List,
      kekSalt,
    );

    // Encrypt the key with this derived key
    final encryptedKeyData =
        CryptoUtil.encryptSync(masterKey!, derivedKeyResult.key);

    final existingAttributes = getKeyAttributes();

    return existingAttributes!.copyWith(
      kekSalt: Sodium.bin2base64(kekSalt),
      encryptedKey: Sodium.bin2base64(encryptedKeyData.encryptedData!),
      keyDecryptionNonce: Sodium.bin2base64(encryptedKeyData.nonce!),
      memLimit: derivedKeyResult.memLimit,
      opsLimit: derivedKeyResult.opsLimit,
    );
  }

  Future<void> decryptAndSaveSecrets(
    String password,
    KeyAttributes attributes,
  ) async {
    _logger.info('Start decryptAndSaveSecrets');
    validatePreVerificationStateCheck(
      attributes,
      password,
      getEncryptedToken(),
    );
    _logger.info('state validation done');
    final kek = await CryptoUtil.deriveKey(
      utf8.encode(password) as Uint8List,
      Sodium.base642bin(attributes.kekSalt),
      attributes.memLimit,
      attributes.opsLimit,
    ).onError((e, s) {
      _logger.severe('deriveKey failed', e, s);
      throw KeyDerivationError();
    });

    _logger.info('user-key done');
    Uint8List key;
    try {
      key = CryptoUtil.decryptSync(
        Sodium.base642bin(attributes.encryptedKey),
        kek,
        Sodium.base642bin(attributes.keyDecryptionNonce),
      );
    } catch (e) {
      _logger.severe('master-key failed, incorrect password?', e);
      throw Exception("Incorrect password");
    }
    _logger.info("master-key done");
    await setKey(Sodium.bin2base64(key));
    final secretKey = CryptoUtil.decryptSync(
      Sodium.base642bin(attributes.encryptedSecretKey),
      key,
      Sodium.base642bin(attributes.secretKeyDecryptionNonce),
    );
    _logger.info("secret-key done");
    await setSecretKey(Sodium.bin2base64(secretKey));
    final token = CryptoUtil.openSealSync(
      Sodium.base642bin(getEncryptedToken()!),
      Sodium.base642bin(attributes.publicKey),
      secretKey,
    );
    _logger.info('appToken done');
    await setToken(
      Sodium.bin2base64(token, variant: Sodium.base64VariantUrlsafe),
    );
  }

  Future<void> verifyPassword(String password) async {
    final KeyAttributes attributes = getKeyAttributes()!;
    _logger.info('state validation done');
    final kek = await CryptoUtil.deriveKey(
      utf8.encode(password) as Uint8List,
      Sodium.base642bin(attributes.kekSalt),
      attributes.memLimit,
      attributes.opsLimit,
    ).onError((e, s) {
      _logger.severe('deriveKey failed', e, s);
      throw KeyDerivationError();
    });

    _logger.info('user-key done');
    try {
      final Uint8List key = CryptoUtil.decryptSync(
        Sodium.base642bin(attributes.encryptedKey),
        kek,
        Sodium.base642bin(attributes.keyDecryptionNonce),
      );
    } catch (e) {
      _logger.severe('master-key failed, incorrect password?', e);
      throw Exception("Incorrect password");
    }
  }

  Future<KeyAttributes> createNewRecoveryKey() async {
    final masterKey = getKey()!;
    final existingAttributes = getKeyAttributes();

    // Create a recovery key
    final recoveryKey = CryptoUtil.generateKey();

    // Encrypt master key and recovery key with each other
    final encryptedMasterKey = CryptoUtil.encryptSync(masterKey, recoveryKey);
    final encryptedRecoveryKey = CryptoUtil.encryptSync(recoveryKey, masterKey);

    return existingAttributes!.copyWith(
      masterKeyEncryptedWithRecoveryKey:
          Sodium.bin2base64(encryptedMasterKey.encryptedData!),
      masterKeyDecryptionNonce: Sodium.bin2base64(encryptedMasterKey.nonce!),
      recoveryKeyEncryptedWithMasterKey:
          Sodium.bin2base64(encryptedRecoveryKey.encryptedData!),
      recoveryKeyDecryptionNonce:
          Sodium.bin2base64(encryptedRecoveryKey.nonce!),
    );
  }

  Future<void> recover(String recoveryKey) async {
    // check if user has entered mnemonic code
    if (recoveryKey.contains(' ')) {
      if (recoveryKey.split(' ').length != mnemonicKeyWordCount) {
        throw AssertionError(
          'recovery code should have $mnemonicKeyWordCount words',
        );
      }
      recoveryKey = bip39.mnemonicToEntropy(recoveryKey);
    }
    final attributes = getKeyAttributes();
    Uint8List masterKey;
    try {
      masterKey = await CryptoUtil.decrypt(
        Sodium.base642bin(attributes!.masterKeyEncryptedWithRecoveryKey),
        Sodium.hex2bin(recoveryKey),
        Sodium.base642bin(attributes.masterKeyDecryptionNonce),
      );
    } catch (e) {
      _logger.severe(e);
      rethrow;
    }
    await setKey(Sodium.bin2base64(masterKey));
    final secretKey = CryptoUtil.decryptSync(
      Sodium.base642bin(attributes.encryptedSecretKey),
      masterKey,
      Sodium.base642bin(attributes.secretKeyDecryptionNonce),
    );
    await setSecretKey(Sodium.bin2base64(secretKey));
    final token = CryptoUtil.openSealSync(
      Sodium.base642bin(getEncryptedToken()!),
      Sodium.base642bin(attributes.publicKey),
      secretKey,
    );
    await setToken(
      Sodium.bin2base64(token, variant: Sodium.base64VariantUrlsafe),
    );
  }

  String getHttpEndpoint() {
    return endpoint;
  }

  String? getToken() {
    _cachedToken ??= _preferences.getString(tokenKey);
    return _cachedToken;
  }

  bool isLoggedIn() {
    return getToken() != null;
  }

  Future<void> setToken(String token) async {
    _cachedToken = token;
    await _preferences.setString(tokenKey, token);
    Bus.instance.fire(SignedInEvent());
  }

  Future<void> setEncryptedToken(String encryptedToken) async {
    await _preferences.setString(encryptedTokenKey, encryptedToken);
  }

  String? getEncryptedToken() {
    return _preferences.getString(encryptedTokenKey);
  }

  String? getEmail() {
    return _preferences.getString(emailKey);
  }

  Future<void> setEmail(String email) async {
    await _preferences.setString(emailKey, email);
  }

  String? getName() {
    return _preferences.getString(nameKey);
  }

  Future<void> setName(String name) async {
    await _preferences.setString(nameKey, name);
  }

  int? getUserID() {
    return _preferences.getInt(userIDKey);
  }

  Future<void> setUserID(int userID) async {
    await _preferences.setInt(userIDKey, userID);
  }

  Set<String> getPathsToBackUp() {
    if (_preferences.containsKey(foldersToBackUpKey)) {
      return _preferences.getStringList(foldersToBackUpKey)!.toSet();
    } else {
      return <String>{};
    }
  }

  Future<void> setKeyAttributes(KeyAttributes attributes) async {
    await _preferences.setString(keyAttributesKey, attributes.toJson());
  }

  KeyAttributes? getKeyAttributes() {
    final jsonValue = _preferences.getString(keyAttributesKey);
    if (jsonValue == null) {
      return null;
    } else {
      return KeyAttributes.fromJson(jsonValue);
    }
  }

  Future<void> setKey(String? key) async {
    _key = key;
    if (key == null) {
      await _secureStorage.delete(
        key: keyKey,
        iOptions: _secureStorageOptionsIOS,
      );
    } else {
      await _secureStorage.write(
        key: keyKey,
        value: key,
        iOptions: _secureStorageOptionsIOS,
      );
    }
  }

  Future<void> setSecretKey(String? secretKey) async {
    _secretKey = secretKey;
    if (secretKey == null) {
      await _secureStorage.delete(
        key: secretKeyKey,
        iOptions: _secureStorageOptionsIOS,
      );
    } else {
      await _secureStorage.write(
        key: secretKeyKey,
        value: secretKey,
        iOptions: _secureStorageOptionsIOS,
      );
    }
  }

  Uint8List? getKey() {
    return _key == null ? null : Sodium.base642bin(_key!);
  }

  Uint8List? getSecretKey() {
    return _secretKey == null ? null : Sodium.base642bin(_secretKey!);
  }

  Uint8List getRecoveryKey() {
    final keyAttributes = getKeyAttributes()!;
    return CryptoUtil.decryptSync(
      Sodium.base642bin(keyAttributes.recoveryKeyEncryptedWithMasterKey),
      getKey(),
      Sodium.base642bin(keyAttributes.recoveryKeyDecryptionNonce),
    );
  }

  // Caution: This directory is cleared on app start
  String getTempDirectory() {
    return _tempDirectory;
  }

  String getThumbnailCacheDirectory() {
    return _thumbnailCacheDirectory;
  }

  String getOldSharedMediaCacheDirectory() {
    return _sharedTempMediaDirectory;
  }

  String getSharedMediaDirectory() {
    return _sharedDocumentsMediaDirectory;
  }

  bool hasConfiguredAccount() {
    return isLoggedIn() && _key != null;
  }

  bool shouldBackupOverMobileData() {
    if (_preferences.containsKey(keyShouldBackupOverMobileData)) {
      return _preferences.getBool(keyShouldBackupOverMobileData)!;
    } else {
      return false;
    }
  }

  int getAlbumGridSize() {
    if (_preferences.containsKey(keyAlbumGridSize)) {
      return _preferences.getInt(keyAlbumGridSize)!;
    } else {
      return defaultAlbumGridSize;
    }
  }

  Future<void> setAlbumGridSize(int value) async {
    await _preferences.setInt(keyAlbumGridSize, value);
  }

  Future<void> setBackupOverMobileData(bool value) async {
    await _preferences.setBool(keyShouldBackupOverMobileData, value);
    if (value) {
      SyncService.instance.sync().ignore();
    }
  }

  bool shouldBackupVideos() {
    if (_preferences.containsKey(keyShouldBackupVideos)) {
      return _preferences.getBool(keyShouldBackupVideos)!;
    } else {
      return true;
    }
  }

  bool shouldKeepDeviceAwake() {
    final keepAwake = _preferences.get(keyShouldKeepDeviceAwake);
    return keepAwake == null ? false : keepAwake as bool;
  }

  Future<void> setShouldKeepDeviceAwake(bool value) async {
    await _preferences.setBool(keyShouldKeepDeviceAwake, value);
    await Wakelock.toggle(enable: value);
  }

  Future<void> setShouldBackupVideos(bool value) async {
    await _preferences.setBool(keyShouldBackupVideos, value);
    if (value) {
      SyncService.instance.sync().ignore();
    } else {
      SyncService.instance.onVideoBackupPaused();
    }
  }

  bool shouldShowLockScreen() {
    if (_preferences.containsKey(keyShouldShowLockScreen)) {
      return _preferences.getBool(keyShouldShowLockScreen)!;
    } else {
      return false;
    }
  }

  Future<void> setShouldShowLockScreen(bool value) {
    return _preferences.setBool(keyShouldShowLockScreen, value);
  }

  bool shouldHideFromRecents() {
    return _preferences.getBool(keyShouldHideFromRecents) ?? false;
  }

  Future<void> setShouldHideFromRecents(bool value) {
    return _preferences.setBool(keyShouldHideFromRecents, value);
  }

  void setVolatilePassword(String volatilePassword) {
    _volatilePassword = volatilePassword;
  }

  String? getVolatilePassword() {
    return _volatilePassword;
  }

  Future<void> setHasSelectedAnyBackupFolder(bool val) async {
    await _preferences.setBool(keyHasSelectedAnyBackupFolder, val);
  }

  bool hasSelectedAnyBackupFolder() {
    return _preferences.getBool(keyHasSelectedAnyBackupFolder) ?? false;
  }

  bool hasSelectedAllFoldersForBackup() {
    return _preferences.getBool(hasSelectedAllFoldersForBackupKey) ?? false;
  }

  Future<void> setSelectAllFoldersForBackup(bool value) async {
    await _preferences.setBool(hasSelectedAllFoldersForBackupKey, value);
  }

  Future<void> _migrateSecurityStorageToFirstUnlock() async {
    final hasMigratedSecureStorageToFirstUnlock =
        _preferences.getBool(hasMigratedSecureStorageToFirstUnlockKey) ?? false;
    if (!hasMigratedSecureStorageToFirstUnlock &&
        _key != null &&
        _secretKey != null) {
      await _secureStorage.write(
        key: keyKey,
        value: _key,
        iOptions: _secureStorageOptionsIOS,
      );
      await _secureStorage.write(
        key: secretKeyKey,
        value: _secretKey,
        iOptions: _secureStorageOptionsIOS,
      );
      await _preferences.setBool(
        hasMigratedSecureStorageToFirstUnlockKey,
        true,
      );
    }
  }

  Future<String> _getOrCreateAnonymousUserID() async {
    if (!_preferences.containsKey(anonymousUserIDKey)) {
      //ignore: prefer_const_constructors
      await _preferences.setString(anonymousUserIDKey, Uuid().v4());
    }
    return _preferences.getString(anonymousUserIDKey)!;
  }
}
