//
//  DylibInfo.swift
//  Feather
//
//  Created by David Wojcik III on 10/7/25.
//


import Foundation

struct DylibInfo: Identifiable {
    let id = UUID()
    let name: String
    let originalPath: String
    let size: Int64
    let extractedURL: URL?
    
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
