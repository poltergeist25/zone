import Foundation
import CryptoKit

struct UpdateResumeRequest:Codable,Equatable {
    var schema=1
    let operationID:String
    let fromBuild:String
    let toBuild:String
    let sourcePID:Int32
    let createdAt:Double
    let expiresAt:Double
    func valid(at now:Double)->Bool {
        schema==1 && UUID(uuidString:operationID) != nil && !fromBuild.isEmpty && !toBuild.isEmpty && fromBuild != toBuild && sourcePID>0 &&
        [now,createdAt,expiresAt].allSatisfy(\.isFinite) && expiresAt>createdAt && expiresAt-createdAt<=300 && now>=createdAt-5 && now<expiresAt
    }
}

enum UpdateSessionMode:String,Codable {case tracking,paused,off,setup}
struct UpdateSessionState:Codable,Equatable {
    let mode:UpdateSessionMode
    let cameraID:String
    let pauseUntilUnix:Double?
    let page:String
    let controlsVisible:Bool
    let preferencesDigest:String
    var valid:Bool {
        ["Posture","Progress","Settings"].contains(page) &&
        (pauseUntilUnix?.isFinite ?? true) &&
        (preferencesDigest=="absent" || (preferencesDigest.count==64 && preferencesDigest.allSatisfy{$0.isHexDigit})) &&
        ((mode != .tracking && mode != .paused) || !cameraID.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
    }
}
struct UpdateResumeReceipt:Codable,Equatable {
    var schema=1
    let request:UpdateResumeRequest
    let state:UpdateSessionState
}

/// No background timer or per-frame IO. Read once on update termination/launch.
/// The installer stages a signed app, requests a normal exit, and waits for this
/// app-authored receipt before swapping bundles. Ordinary launches never resume.
final class UpdateResumeStore {
    let directory:URL
    let build:String
    let processID:Int32
    private let now:()->Date
    private(set) var rejection:String?
    var requestURL:URL {directory.appendingPathComponent("update-request.json")}
    var receiptURL:URL {directory.appendingPathComponent("update-resume.json")}
    var preferencesURL:URL {directory.appendingPathComponent("preferences.json")}
    init(directory:URL,build:String,processID:Int32=ProcessInfo.processInfo.processIdentifier,now:@escaping ()->Date=Date.init) {
        self.directory=directory;self.build=build;self.processID=processID;self.now=now
    }
    static func digest(_ url:URL)throws->String {
        guard FileManager.default.fileExists(atPath:url.path) else{return "absent"}
        return SHA256.hash(data:try Data(contentsOf:url)).map{String(format:"%02x",$0)}.joined()
    }
    func currentDigest()throws->String {try Self.digest(preferencesURL)}
    func cancel() {
        try? FileManager.default.removeItem(at:requestURL)
        try? FileManager.default.removeItem(at:receiptURL)
    }
    @discardableResult func prepareForTermination(_ state:UpdateSessionState)throws->Bool {
        guard let data=try? Data(contentsOf:requestURL),let request=try? JSONDecoder().decode(UpdateResumeRequest.self,from:data),
              request.valid(at:now().timeIntervalSince1970),request.fromBuild==build,request.sourcePID==processID,state.valid,
              state.preferencesDigest == (try currentDigest()) else{cancel();return false}
        let receipt=UpdateResumeReceipt(request:request,state:state)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONEncoder().encode(receipt).write(to:receiptURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:receiptURL.path)
        return true
    }
    /// Atomic rename claims the handoff before any camera action. A crash/failure
    /// cannot replay it on a later ordinary launch, including the same build.
    func consume()throws->UpdateResumeReceipt? {
        rejection=nil
        guard FileManager.default.fileExists(atPath:receiptURL.path) else {
            try? FileManager.default.removeItem(at:requestURL);return nil
        }
        let claimed=directory.appendingPathComponent(".update-consumed-\(UUID().uuidString).json")
        do {try FileManager.default.moveItem(at:receiptURL,to:claimed)}
        catch {rejection="The update handoff could not be consumed safely.";throw error}
        defer {try? FileManager.default.removeItem(at:claimed);try? FileManager.default.removeItem(at:requestURL)}
        guard let requestData=try? Data(contentsOf:requestURL),let request=try? JSONDecoder().decode(UpdateResumeRequest.self,from:requestData),
              let data=try? Data(contentsOf:claimed),let receipt=try? JSONDecoder().decode(UpdateResumeReceipt.self,from:data),receipt.schema==1,
              receipt.request==request,request.valid(at:now().timeIntervalSince1970),request.toBuild==build,request.sourcePID != processID,
              receipt.state.valid else{rejection="The update handoff was invalid or expired.";return nil}
        guard receipt.state.preferencesDigest == (try currentDigest()) else {
            rejection="Your settings changed after the update was prepared.";return nil
        }
        return receipt
    }
}
