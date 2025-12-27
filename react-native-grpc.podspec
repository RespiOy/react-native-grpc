require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "react-native-grpc"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "13.0" }
  s.source       = { :git => "https://github.com/krishnafkh/react-native-grpc.git", :tag => "#{s.version}" }


  s.source_files = "ios/**/*.{h,m,mm,swift}"
  s.static_framework = true


  s.dependency "React-Core"
  spm_dependency(s,
    url: 'https://github.com/grpc/grpc-swift.git',
    requirement: {kind: 'upToNextMajorVersion', minimumVersion: '1.27.1'},
    products: ['GRPC']
  )

  pods_root = 'Pods'
end
