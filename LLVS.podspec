Pod::Spec.new do |s|

  s.name         = "LLVS"
  s.version      = "0.1"
  s.summary      = "A decentralized, versioned key-value storage framework in Swift"

  s.description  =  <<-DESC
                    Ever wish it was as easy to move your app's data around as it is to push and pull 
                    your source code with a tool like Git? 
                    
                    LLVS works like a standard key-value store, except that it attaches a version to
                    every piece of stored data — it forms a complete history of changes. 
                    Just as with Git, you can retrieve the values for 
                    any version, determine the differences between two versions, 
                    and merge divergent versions.
                    
                    LLVS is also decentralized: you can send and receive versions from other stores, 
                    in the same way that you push and pull from other repositories with Git.
                    DESC

  s.homepage = "https://gitlab.com/llvs/llvs"
  s.license = { 
    :type => 'MIT', 
    :file => 'LICENCE.txt' 
  }
  s.author = { "Drew McCormack" => "drewmccormack@mac.com" }
  
  s.ios.deployment_target = '10.0'
  s.osx.deployment_target = '10.12'
  
  s.swift_version = '5.0'

  s.source        = { 
    :git => 'https://gitlab.com/llvs/llvs.git', 
    :tag => s.version.to_s
  }
    
  s.default_subspec = 'Core'
  
  s.subspec 'Core' do |ss|
    ss.source_files = 'Source/LLVS/*/*.swift'
  end
  
  s.subspec 'CloudKit' do |ss|
    ss.dependency 'LLVS/Core'
    ss.framework = 'CloudKit'
    ss.source_files = 'Source/LLVSCloudKit/*.swift'
  end

end
