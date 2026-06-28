Pod::Spec.new do |s|
  s.name             = 'QCBandSDK'
  s.version          = '1.0.0'
  s.summary          = 'QC Wireless Band SDK for iOS'
  s.description      = 'QC Wireless Band SDK — pre-built xcframework for AGP Wear Hub'
  s.homepage         = 'https://github.com/agptech'
  s.license          = { :type => 'Commercial' }
  s.author           = { 'AGP Tech' => 'dev@agptech.com' }
  s.platform         = :ios, '13.0'
  s.source           = { :path => '.' }

  # Pre-built framework located in ios/Frameworks/
  s.vendored_frameworks = 'Frameworks/QCBandSDK.framework'

  # System frameworks required by QCBandSDK
  s.frameworks = 'CoreBluetooth', 'UIKit', 'Foundation'
end
