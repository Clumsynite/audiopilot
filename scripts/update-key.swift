// Ed25519 key for signing update.json, so an installed AudioPilot only accepts updates from our releases.
//
//   swift scripts/update-key.swift generate <private-key-file>   writes the key, prints the public key for Info.plist
//   swift scripts/update-key.swift sign <file>                   prints a base64 signature; key from $UPDATE_SIGNING_KEY
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: update-key.swift generate <private-key-file> | sign <file>") }

switch args[1] {
case "generate":
    let path = args[2]
    guard !FileManager.default.fileExists(atPath: path) else { fail("\(path) exists; refusing to replace a signing key") }
    let key = Curve25519.Signing.PrivateKey()
    let created = FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                                 attributes: [.posixPermissions: 0o600])
    guard created else { fail("couldn't write \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    let encoded = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard let raw = Data(base64Encoded: encoded), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("UPDATE_SIGNING_KEY isn't a base64 Ed25519 private key")
    }
    guard let data = FileManager.default.contents(atPath: args[2]) else { fail("can't read \(args[2])") }
    print(try key.signature(for: data).base64EncodedString())
default:
    fail("unknown command \(args[1])")
}
