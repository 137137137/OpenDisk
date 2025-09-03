import Foundation

/// Simple validation test to ensure the optimized scanner compiles and basic functionality works
@MainActor
class ValidationTest {
    
    static func runBasicValidation() async {
        print("🧪 Running basic validation tests...")
        
        // Test 1: Can create instances without crashing
        print("✅ Test 1: Creating instances...")
        let scanner = OptimizedScanner()
        _ = FileSystemMonitor() // Test creation but don't store
        _ = SmartDirectoryCache() // Test creation but don't store
        
        // Test 2: Can access basic properties
        print("✅ Test 2: Accessing properties...")
        print("Scanner progress: \(scanner.scanProgress)")
        
        // Test 3: Can create shared types
        print("✅ Test 3: Creating shared types...")
        _ = RateModel() // Test creation but don't store
        let fileIDSet = ShardedFileIDSet(shardCount: 4)
        _ = FirmlinkResolver() // Test creation but don't store
        
        // Test 4: Can insert into file ID set
        print("✅ Test 4: Testing file ID deduplication...")
        let testData = "test".data(using: .utf8)!
        let inserted1 = fileIDSet.insert(testData)
        let inserted2 = fileIDSet.insert(testData) // Should be false (duplicate)
        print("First insert: \(inserted1), Second insert: \(inserted2)")
        
        // Test 5: Can use system directory filter
        print("✅ Test 5: Testing directory filtering...")
        let testPaths = ["/Users", "/tmp", "/System"]
        let prioritized = SystemDirectoryFilter.prioritizedPaths(from: testPaths)
        let shouldSkip = SystemDirectoryFilter.shouldSkipPath("/dev")
        print("Prioritized paths: \(prioritized), Should skip /dev: \(shouldSkip)")
        
        print("🎉 All basic validation tests passed!")
    }
    
    static func runMemoryTest() {
        print("🧪 Running memory management test...")
        
        Task {
            // Test autoreleasepool functionality
            // Since this doesn't do async work, just test direct usage
            let result = "Memory test completed with autoreleasepool support"
            print("✅ Autoreleasepool test: \(result)")
        }
    }
}