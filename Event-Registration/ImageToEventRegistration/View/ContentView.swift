//
//  ContentView.swift
//  ImageToEventRegistration
//
//  Created by Muddsar Butt on 2025-11-03.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("Image → Event Registration")
                    .font(.title2)
                NavigationLink("Scan Event From Image") {
                    EventScannerView()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Event Importer")
        }
    }
}

#Preview {
    ContentView()
}
