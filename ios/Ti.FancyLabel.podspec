
Pod::Spec.new do |s|

    s.name         = "Ti.FancyLabel"
    s.version      = "1.0.0"
    s.summary      = "The Ti.FancyLabel Titanium module."

    s.description  = <<-DESC
                     A Titanium view (Ti.FancyLabel.createLabel) that fades in
                     streamed text word-by-word or character-by-character.
                     Each word/character is its own SwiftUI view inside a
                     custom wrapping Layout, animated via .animation(value:)
                     (iOS 16+).
                     DESC

   s.homepage     = "https://example.com"
    s.license      = { :type => "Apache 2", :file => "LICENSE" }
    s.author       = 'Author'

    s.platform     = :ios
    # The custom word-wrap Layout protocol requires iOS 16+.
    s.ios.deployment_target = '16.0'

    s.source       = { :git => "https://github.com/<organization>/<repository>.git" }

    s.ios.weak_frameworks = 'UIKit', 'Foundation', 'SwiftUI'

    s.ios.dependency 'TitaniumKit'

    s.public_header_files = 'Classes/*.h'
    s.source_files = 'Classes/*.{h,m,swift}'
  end
