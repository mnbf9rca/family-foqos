//
//  FoqosWidgetBundle.swift
//  FoqosWidget
//
//  Created by Ali Waseem on 2025-03-11.
//

import FoqosShared
import SwiftUI
import WidgetKit

@main
struct FoqosWidgetBundle: WidgetBundle {
  init() {
    SharedData.configure(
      suite: UserDefaults(suiteName: "group.com.cynexia.family-foqos")!
    )
  }

  var body: some Widget {
    ProfileControlWidget()
    FoqosWidgetLiveActivity()
  }
}
