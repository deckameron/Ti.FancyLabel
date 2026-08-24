//
//  TiFancylabelModule.swift
//  Ti.FancyLabel
//
//  Copyright (c) 2026 Upflix Inc. All rights reserved.
//
//  Ti.FancyLabel exposes a single view: Ti.FancyLabel.createLabel({...}).
//  The real implementation lives in TiFancylabelLabelProxy / TiFancylabelLabel.
//  This module class only needs to identify itself to the Titanium runtime.
//

import UIKit
import TitaniumKit

/**
 
 Titanium Swift Module Requirements
 ---
 
 1. Use the @objc annotation to expose your class to Objective-C (used by the Titanium core)
 2. Use the @objc annotation to expose your method to Objective-C as well.
 3. Method arguments always have the "[Any]" type, specifying a various number of arguments.
 Unwrap them like you would do in Swift, e.g. "guard let arguments = arguments, let message = arguments.first"
 4. You can use any public Titanium API like before, e.g. TiUtils. Remember the type safety of Swift, like Int vs Int32
 and NSString vs. String.
 
 */

@objc(TiFancylabelModule)
class TiFancylabelModule: TiModule {

  func moduleGUID() -> String {
    return "05983a68-b4fb-4f8a-b5af-db0c7743db54"
  }

  override func moduleId() -> String! {
    return "ti.fancylabel"
  }

  override func startup() {
    super.startup()
    debugPrint("[DEBUG] \(self) loaded")
  }
}
