import 'dart:collection';
import 'dart:typed_data';

import 'package:byte_extensions/byte_extensions.dart';
import 'package:collection/collection.dart';
import 'package:crypto_keys/crypto_keys.dart';
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:logger/logger.dart';

import 'constants.dart' as c;
import 'db/credential.dart';
import 'enums/public_key_credential_type.dart';
import 'exceptions.dart';
import 'models/assertion.dart';
import 'models/attestation.dart';
import 'models/authentication_localization_options.dart';
import 'models/cred_type_pub_key_algo_pair.dart';
import 'models/get_assertion_options.dart';
import 'models/make_credential_options.dart';
import 'models/none_attestation.dart';
import 'util/credential_safe.dart';
import 'util/webauthn_cryptography.dart';

class Authenticator {
  // Allow external referednces
  static const shaLength = c.shaLength;
  static const authenticationDataLength = c.authenticationDataLength;

  // ignore: constant_identifier_names
  static const ES256_COSE = CredTypePubKeyAlgoPair(
    credType: PublicKeyCredentialType.publicKey,
    pubKeyAlgo: -7,
  );

  /// Create a new instance of the Authenticator.
  ///
  /// Pass `true` for [authenticationRequired] if we want to require authentication
  /// before allowing the key to be accessed and used.
  /// Pass `true` for [strongboxRequired] if we want this key to be managed by the
  /// system strongbox.
  /// The default dependencies can be overwritten by passing a mock, or other instance,
  /// to [credentialSafe] or [cryptography]
  ///
  /// NOTE: The options [strongboxRequired] is currently ignored because we don't
  /// have access to the system strongbox on all the platforms
  Authenticator(
    bool authenticationRequired,
    bool strongboxRequired, {
    CredentialSafe? credentialSafe,
    WebauthnCrytography? cryptography,
    LocalAuthentication? localAuth,
  })  : _crypto = cryptography ?? const WebauthnCrytography(),
        _credentialSafe = credentialSafe ??
            CredentialSafe(
              authenticationRequired: authenticationRequired,
              strongboxRequired: strongboxRequired,
              localAuth: localAuth,
            ),
        _localAuth = localAuth ?? LocalAuthentication();

  final CredentialSafe _credentialSafe;
  final WebauthnCrytography _crypto;
  final LocalAuthentication _localAuth;

  final Logger _logger = Logger();

  /// The secure store for our credentials
  @visibleForTesting
  CredentialSafe get credentialSafe {
    return _credentialSafe;
  }

  /// The crypto handling functinality
  @visibleForTesting
  WebauthnCrytography get crytography {
    return _crypto;
  }

  /// Perform the authenticatorMakeCredential operation as defined by the WebAuthn spec
  /// @see https://www.w3.org/TR/webauthn/#sctn-op-make-cred
  ///
  /// The [options] to create the credential should be passed. An [Attestation]
  /// containing the new credential and attestation information is returned.
  Future<Attestation> makeCredential(MakeCredentialOptions options,
      {var localizationOptions =
          const AuthenticationLocalizationOptions()}) async {
    // We are going to use a flag rather than explicitly invoking deny-behavior
    // because the spec asks us to pretend everything is normal while asynchronous
    // operations (like asking user consent) happen to ensure privacy guarantees.
    // Flag for whether our credential was in the exclude list
    var excludeFlag = false;

    // Step 1: check if all supplied parameters are syntactically well-formed and of the correct length
    final optionsError = options.hasError();
    if (optionsError != null) {
      _logger.w(
          'Credential options are not syntactically well-formed: $optionsError');
      throw InvalidArgumentException(optionsError,
          arguments: {'options': options});
    }

    // Step 2: Check if we support a compatible credential type
    if (!options.credTypesAndPubKeyAlgs.contains(ES256_COSE)) {
      _logger.w('Only ES256 is supported');
      throw InvalidArgumentException(
          'Options must include the ES256 algorithm');
    }

    // Step 3: Check excludeCredentialDescriptorList for existing credentials for this RP
    if (options.excludeCredentialDescriptorList != null) {
      for (var descriptor in options.excludeCredentialDescriptorList!) {
        // If we have a credential identified by this id, flag as excluding
        final existingCreds =
            await _credentialSafe.getCredentialBySourceKey(descriptor.id);
        if (existingCreds != null &&
            existingCreds.rpId == options.rpEntity.id &&
            existingCreds.type == descriptor.type) {
          excludeFlag = true;
          break;
        }
      }
    }

    // Step 4: Check requireResidentKey
    // Our authenticator will store resident keys regardless, so we can disregard the value of this parameter

    // Step 5: Check requireUserVerification
    final supportsUserVerifiation =
        await _credentialSafe.supportsUserVerification();
    if (options.requireUserVerification && !supportsUserVerifiation) {
      _logger.w('User verification is required but not available');
      throw CredentialCreationException(
          'User verification is required but not available');
    }

    // NOTE: We are switching the order of steps 6 and 7/8 because we need to have the credential
    // created in order to  use it in a biometric prompt. We will delete the credential
    // if the biometric prompt fails.

    // Step 7: Generate a new credential
    late Credential credentialSource;
    try {
      credentialSource = await _credentialSafe.generateCredential(
          options.rpEntity.id, options.userEntity.id, options.userEntity.name);
    } on Exception catch (e) {
      _logger.e('Couldn\'t generate credential', error : e);
      throw CredentialCreationException('Couldn\'t generate credential');
    }

    // Step 6: Obtain user consent for creating a new credential
    // If we need to obtain user verification, prompt for that
    // Otherwise, just create the new attestation object
    Signer<PrivateKey>? signer;
    late Attestation attestation;
    if (supportsUserVerifiation) {
      final reason = localizationOptions.localizedReason ??
          'Authenticate to create a new credential';

      final success = await _localAuth.authenticate(
          localizedReason: reason,
          authMessages: localizationOptions.authMessages,
          options: AuthenticationOptions(
            useErrorDialogs: localizationOptions.userErrorDialogs,
          ));
      // TODO local_auth is not going to work for what we need here.
      // It is not returning the signature from keystore. If we look
      // at the flutter_biometrics plugin, it is much closer. It is not
      // actually letting us pass a crypto object and it is discgarding
      // the local credential and creating a new key. We're probably
      // going to need our own solution in the future

      // If we failed, error out
      if (!success) {
        throw CredentialCreationException(
            'Failed to authenticate with biometrics');
      }

      // Create a signer to use for this
      // TODO this should be passed to the biometrics and we should get another
      // signer back that we can use. Unless that is impossible... ... ...
      // Unless passing that signer means that the auth is going to try to use
      // something in the native android keychain. Because our key isn't there.
      // In which case the flutter_biometrics plugin might work exactly as we need.
      final keyPair = await _credentialSafe
          .getKeyPairByAlias(credentialSource.keyPairAlias);
      if (keyPair == null) {
        throw KeyPairNotFound(credentialSource.keyPairAlias);
      }
      signer = WebauthnCrytography.createSigner(keyPair.privateKey!);
    }

    // Steps 8-13, with the optional signer
    attestation = await _createAttestation(options, credentialSource, signer);

    // We finish up Step 3 here by checking excludeFlag at the end (so we've still gotten
    // the user's conset to create a credential etc)
    if (excludeFlag) {
      await _credentialSafe.deleteCredential(credentialSource);
      _logger.w('Credential is excluded by excludeCredentialDescriptorList');
      throw CredentialCreationException(
          'Credential is excluded by excludeCredentialDescriptorList');
    }

    return attestation;
  }

  Future<Assertion> getAssertion(GetAssertionOptions options,
      {var localizationOptions =
          const AuthenticationLocalizationOptions()}) async {
    // Step 1: Check if all supplied parameters are well-formed
    final optionsError = options.hasError();
    if (optionsError != null) {
      _logger.w(
          'Assertion options are not syntactically well-formed: $optionsError');
      throw InvalidArgumentException(optionsError,
          arguments: {'options': options});
    }

    // Step 2-3: Parse allowCredentialDescriptorList
    // This is done after we fetch the keys from the DB

    // Step 4-5: Get keys that match this relying party ID
    var credentials = await _credentialSafe.getKeysForEntity(options.rpId);

    // Step 2-3: Actually parse allowCredentialDescriptorList
    if (options.allowCredentialDescriptorList != null &&
        options.allowCredentialDescriptorList!.isNotEmpty) {
      final filteredCredentials = <Credential>[];

      const eq = ListEquality();
      final allowedCredentials = HashSet<Uint8List>(
        equals: eq.equals,
        hashCode: eq.hash,
      );
      for (var descriptor in options.allowCredentialDescriptorList!) {
        allowedCredentials.add(descriptor.id);
      }

      for (var credential in credentials) {
        if (allowedCredentials.contains(credential.keyId)) {
          filteredCredentials.add(credential);
        }
      }

      credentials = filteredCredentials;
    }

    // Step 6: Error if none exist
    if (credentials.isEmpty) {
      final message = 'No credentials exist for rpId: ${options.rpId}';
      _logger.w(message);
      throw GetAssertionException(message);
    }

    // Step 7: Allow the user to pick a specific credential, get verification
    late Credential selectedCredential;
    if (credentials.length == 1) {
      selectedCredential = credentials[0];
    } else {
      // TODO implement selector
      selectedCredential = credentials.last;
    }

    Signer<PrivateKey>? signer;

    // Get verification if necessary
    final keyNeedsUnlocking = await _credentialSafe
            .keyRequiresVerification(selectedCredential.keyPairAlias) ??
        false;
    if (options.requireUserVerification || keyNeedsUnlocking) {
      final reason = localizationOptions.localizedReason ??
          'Authenticate to create an assertion';

      final success = await _localAuth.authenticate(
          localizedReason: reason,
          authMessages: localizationOptions.authMessages,
          options: AuthenticationOptions(
            useErrorDialogs: localizationOptions.userErrorDialogs,
          ));

      // If we failed, error out
      if (!success) {
        throw CredentialCreationException(
            'Failed to authenticate with biometrics');
      }

      // Create a signer to use for this
      // TODO this should be passed to the biometrics and we should get another
      // signer back that we can use. Unless that is impossible... ... ...
      // Unless passing that signer means that the auth is going to try to use
      // something in the native android keychain. Because our key isn't there.
      // In which case the flutter_biometrics plugin might work exactly as we need.
      final keyPair = await _credentialSafe
          .getKeyPairByAlias(selectedCredential.keyPairAlias);
      if (keyPair == null) {
        throw KeyPairNotFound(selectedCredential.keyPairAlias);
      }
      signer = WebauthnCrytography.createSigner(keyPair.privateKey!);
    }

    // Step 8-13
    return await _createAssertion(options, selectedCredential, signer);
  }

  /// The second half of the makeCredential process
  Future<Attestation> _createAttestation(
      MakeCredentialOptions options, Credential credential,
      [Signer<PrivateKey>? signer]) async {
    // TODO Step 9: process extensions
    // Current not supported

    // Step 10: Allocate a signature counter for the new credential, initialized at 0
    // It is created and initialized to 0 during creation

    // Step 11: Generate attested credential data
    final attestedCredentialData =
        await _constructAttestedCredentialData(credential); // 127 bytes
    assert(attestedCredentialData.length == 127);

    // Step 12: Create authenticatorData byte array
    final rpIdHash = WebauthnCrytography.sha256(options.rpEntity.id);
    final authenticatorData = await _constructAuthenticatorData(
        rpIdHash, attestedCredentialData, 0); // 164 bytes
    assert(authenticatorData.length == 164);

    // Step 13: Return attestation object
    return await _constructAttestation(authenticatorData,
        options.clientDataHash, credential.keyPairAlias, signer);
  }

  /// Constructs an attestedCredentialData object per the WebAuthn Spec
  /// @see https://www.w3.org/TR/webauthn/#sec-attested-credential-data
  Future<Uint8List> _constructAttestedCredentialData(
      Credential credential) async {
    // | AAGUID | L | credentialId | credentialPublicKey |
    // |   16   | 2 |      32      |          n          |
    // total size: 50+n (for ES256 keypair, n = 77), so total size is 127
    final keyPair =
        await _credentialSafe.getKeyPairByAlias(credential.keyPairAlias);
    if (keyPair == null) {
      throw KeyPairNotFound(credential.keyPairAlias);
    }

    final encodedPublicKey =
        CredentialSafe.coseEncodePublicKey(keyPair.publicKey!);

    final data = BytesBuilder()
      ..add(List.filled(16, 0)) // AAGUID will be 16 bytes of zeros
      ..add(credential.keyId.length.asBytes(type: IntType.int16))
      ..add(credential.keyId) // credentialId
      ..add(encodedPublicKey); // credentialPublicKey
    return data.toBytes();
  }

  /// Constructs an authenticatorData object per the WebAuthn spec
  /// @see https://www.w3.org/TR/webauthn/#sec-authenticator-data
  Future<Uint8List> _constructAuthenticatorData(
      Uint8List rpIdHash, Uint8List? credentialData, int authCounter) async {
    if (rpIdHash.length != shaLength) {
      throw InvalidArgumentException(
          'rpIdHash must be a $shaLength-byte SHA-256 hash',
          arguments: {'rpIdHash': rpIdHash});
    }
    // | rpIdHash | flags | useCounter | authenticatorData
    // |    32    |   1   |     4      |     127 or 0

    int flags = 0x01; // user present
    if (await _credentialSafe.supportsUserVerification()) {
      flags |= (0x01 << 2); // user verified
    }
    if (credentialData != null && credentialData.isNotEmpty) {
      flags |= (0x01 << 6); // attested credential data included
    }

    final data = BytesBuilder()
      ..add(rpIdHash)
      ..addByte(flags)
      ..add(authCounter.asBytes(type: IntType.int32));
    if (credentialData != null && credentialData.isNotEmpty) {
      data.add(credentialData);
    }
    return data.toBytes();
  }

  /// Construct an AttestationObject per the WebAuthn spec
  /// @see https://www.w3.org/TR/webauthn/#generating-an-attestation-object
  /// A package self-attestation or "none" attestation will be returned
  /// @see https://www.w3.org/TR/webauthn/#attestation-formats
  Future<Attestation> _constructAttestation(
      Uint8List authenticatorData,
      Uint8List clientDataHash,
      String keyPairAlias,
      Signer<PrivateKey>? signer) async {
    // We are going to create a signature over the relevant data fields.
    // See https://www.w3.org/TR/webauthn/#attestation-formats
    // We need to sign the concatenation of the authenticationData and clientDataHash
    // The Attestation knows how to CBOR encode itself

    PrivateKey? privateKey;
    if (signer == null) {
      // Get the key for signing
      final keyPair = await _credentialSafe.getKeyPairByAlias(keyPairAlias);
      if (keyPair == null) {
        throw KeyPairNotFound(keyPairAlias);
      }
      privateKey = keyPair.privateKey;
    }

    final toSign = BytesBuilder()
      ..add(authenticatorData)
      ..add(clientDataHash);

    // Sanity check to make sure the data is the length we are expecting
    assert(toSign.length == 164 + 32);

    // Sign our data
    final signatureBytes = _crypto.performSignature(toSign.toBytes(),
        privateKey: privateKey, signer: signer);

    // Sanity check on signature
    assert(signatureBytes.length == 70);

    // return PackedSelfAttestationObject(authenticatorData, signatureBytes);
    return NoneAttestation(authenticatorData);
  }

  Future<Assertion> _createAssertion(GetAssertionOptions options,
      Credential credential, Signer<PrivateKey>? signer) async {
    late Uint8List signature;
    late Uint8List authenticatorData;
    try {
      // TODO Step 8: Process extensions
      // Currently not supported

      // Step 9: Increment signature counter
      int authCounter =
          await _credentialSafe.incrementCredentialUseCounter(credential);

      // Step 10: Constructor authenticator data
      final rpIdHash = WebauthnCrytography.sha256(options.rpId);
      authenticatorData =
          await _constructAuthenticatorData(rpIdHash, null, authCounter);

      // Step 11: Sign the concatenation authenticatorData || hash
      final data = BytesBuilder()
        ..add(authenticatorData)
        ..add(options.clientDataHash);
      final toSign = data.toBytes();

      PrivateKey? privateKey;
      if (signer == null) {
        // Get the key for signing
        final keyPair =
            await _credentialSafe.getKeyPairByAlias(credential.keyPairAlias);
        if (keyPair == null) {
          throw KeyPairNotFound(credential.keyPairAlias);
        }
        privateKey = keyPair.privateKey;
      }

      signature = _crypto.performSignature(toSign,
          privateKey: privateKey, signer: signer);
    } catch (e) {
      // Step 12: Throw if any errors occured while generating the assertion signature
      _logger.e('Exception occured while generating assertion', error : e);
      throw GetAssertionException(
          'Exception occured while generating assertion');
    }

    // Step 13: package up the results
    return Assertion(
      selectedCredentialId: credential.keyId,
      authenticatorData: authenticatorData,
      signature: signature,
      selectedCredentialUserHandle: credential.userHandle,
    );
  }
}
