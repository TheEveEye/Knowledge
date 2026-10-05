//
//  Item.swift
//  Knowledge
//
//  Created by Oskar on 10/5/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
