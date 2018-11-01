//
//  V4.swift
//  AWSSDKSwift
//
//  Created by Yuki Takei on 2017/03/13.
//
//

import Foundation
import CLibreSSL

extension Signers {
    public final class V4 {

        public var credentials: CredentialProvider

        public let region: Region

        public let service: String

        let identifier = "aws4_request"

        let algorithm = "AWS4-HMAC-SHA256"

        var unsignableHeaders: [String] {
            return [
                "authorization",
                "content-type",
                "content-length",
                "user-agent",
                "presigned-expires",
                "expect",
                "x-amzn-trace-id"
            ]
        }

        func hexEncodedBodyHash(_ data: Data) -> String {
            if data.isEmpty && service == "s3" {
                return "UNSIGNED-PAYLOAD"
            }
            return sha256(data).hexdigest()
        }

        public init(credentials: CredentialProvider, region: Region, service: String) {
            self.credentials = credentials
            self.region = region
            self.service = service
        }

        public func signedURL(url: URL, date: Date = Date(), expires: Int = 86400) -> URL {
            let datetime = V4.timestamp(date)

            let headers = ["Host": url.hostWithPort!]
            let bodyDigest = hexEncodedBodyHash(Data())

            let xQueries = [
                URLQueryItem(name: "X-Amz-Expires", value: "\(expires)"),
                URLQueryItem(name: "X-Amz-Date", value: datetime),
                URLQueryItem(name: "X-Amz-Algorithm", value: algorithm),
                URLQueryItem(name: "X-Amz-Credential", value: credential(datetime).replacingOccurrences(of: "/", with: "%2F")),
                URLQueryItem(name: "X-Amz-SignedHeaders", value: "host"),
            ]

            var queries: [URLQueryItem] = []
            url.query?.components(separatedBy: "&").forEach {
                var q = $0.components(separatedBy: "=")
                if q.count == 2 {
                    queries.append(URLQueryItem(name: q[0], value: q[1]))
                } else {
                    queries.append(URLQueryItem(name: q[0], value: nil))
                }
            }

            let urlString = url.absoluteString.components(separatedBy: "?")[0]+"?"
            var signatureUrlString = urlString+xQueries.sorted {
                $0.name.localizedCompare($1.name) == ComparisonResult.orderedAscending
                }.asStringForURL
            if !queries.isEmpty {
                signatureUrlString += ("&" + queries.asStringForURL)
            }

            let signatureUrl = URL(string: signatureUrlString)!

            let sig = signature(
                url: signatureUrl,
                headers: headers,
                datetime: datetime,
                method: "GET",
                bodyDigest: bodyDigest
            )

            var finalUrlString = urlString
            if !queries.isEmpty {
                finalUrlString += (queries.asStringForURL + "&")
            }
            finalUrlString += xQueries.asStringForURL

            return URL(string: finalUrlString+"&X-Amz-Signature="+sig)!
        }

        public func signedHeaders(url: URL, headers: [String: String], method: String, date: Date = Date(), bodyData: Data) -> [String: String] {
            let datetime = V4.timestamp(date)
            let bodyDigest = hexEncodedBodyHash(bodyData)

            var headersForSign = [
                "x-amz-content-sha256": hexEncodedBodyHash(bodyData),
                "x-amz-date": datetime,
                "Host": url.hostWithPort!,
            ]

            for header in headers {
                if unsignableHeaders.contains(header.key.lowercased()) { continue }
                headersForSign[header.key] = header.value
            }

            headersForSign["Authorization"] = authorization(
                url: url,
                headers: headersForSign,
                datetime: datetime,
                method: method,
                bodyDigest: bodyDigest
            )

            if let token = self.credentials.sessionToken {
                headersForSign["x-amz-security-token"] = token
            }

            return headersForSign
        }

        static func timestamp(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(abbreviation: "UTC")
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter.string(from: date)
        }

        func authorization(url: URL, headers: [String: String], datetime: String, method: String, bodyDigest: String) -> String {
            let cred = credential(datetime)
            let shead = signedHeaders(headers)

            let sig = signature(
                url: url,
                headers: headers,
                datetime: datetime,
                method: method,
                bodyDigest: bodyDigest
            )

            return [
                "AWS4-HMAC-SHA256 Credential=\(cred)",
                "SignedHeaders=\(shead)",
                "Signature=\(sig)",
            ].joined(separator: ", ")
        }

        func credential(_ datetime: String) -> String {
            return "\(credentials.accessKeyId)/\(credentialScope(datetime))"
        }

        func signedHeaders(_ headers: [String:String]) -> String {
            var list = Array(headers.keys).map { $0.lowercased() }.sorted()
            if let index = list.index(of: "authorization") {
                list.remove(at: index)
            }
            return list.joined(separator: ";")
        }

        func canonicalHeaders(_ headers: [String: String]) -> String {
            var list = [String]()
            let keys = Array(headers.keys).sorted {$0.localizedCompare($1) == ComparisonResult.orderedAscending }

            for key in keys {
                if key.caseInsensitiveCompare("authorization") != ComparisonResult.orderedSame {
                    list.append("\(key.lowercased()):\(headers[key]!)")
                }
            }
            return list.joined(separator: "\n")
        }

        func signature(url: URL, headers: [String: String], datetime: String, method: String, bodyDigest: String) -> String {
            let secretAccessKey = "AWS4\(self.credentials.secretAccessKey)"

            let secretBytes = Array(secretAccessKey.utf8)
            let date = hmac(
                string: String(datetime.prefix(upTo: datetime.index(datetime.startIndex, offsetBy: 8))),
                key: secretBytes
            )
            let region = hmac(string: self.region.rawValue, key: date)
            let service = hmac(string: self.service, key: region)
            let credentials = hmac(string: identifier, key: service)
            let string = stringToSign(
                url: url,
                headers: headers,
                datetime: datetime,
                method: method,
                bodyDigest: bodyDigest
            )

            return hmac(string: string, key: credentials).hexdigest()
        }

        func credentialScope(_ datetime: String) -> String {
            return [
                String(datetime.prefix(upTo: datetime.index(datetime.startIndex, offsetBy: 8))),
                region.rawValue,
                service,
                identifier
            ].joined(separator: "/")
        }

        func stringToSign(url: URL, headers: [String: String], datetime: String, method: String, bodyDigest: String) -> String {

            let canonicalRequestString = canonicalRequest(url: url, headers: headers, method: method, bodyDigest: bodyDigest)

            var canonicalRequestBytes = Array(canonicalRequestString.utf8)

            return [
                "AWS4-HMAC-SHA256",
                datetime,
                credentialScope(datetime),
                sha256(&canonicalRequestBytes).hexdigest(),
            ].joined(separator: "\n")
        }

        func canonicalRequest(url: URL, headers: [String: String], method: String, bodyDigest: String) -> String {
            return [
                method,
                url.path,
                url.query ?? "",
                "\(canonicalHeaders(headers))\n",
                signedHeaders(headers),
                bodyDigest
            ].joined(separator: "\n")
        }
    }
}


extension Collection where Iterator.Element == URLQueryItem {
    var asStringForURL: String {
        return self.flatMap({ "\($0.name)=\($0.value ?? "")" }).joined(separator: "&")
    }
}
