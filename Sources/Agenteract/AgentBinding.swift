//
//  AgentBinding.swift
//  AgenteractSwiftExample
//
//  Created by Agenteract
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Agent Binding Properties

public struct AgentBindingProps {
    let testID: String
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?
    var onChangeText: ((String) -> Void)?
    var onSwipe: ((String, String) -> Void)? // direction, velocity
    var scrollViewProxy: Any?
}

// MARK: - Agent Binding View Modifier

public struct AgentBindingModifier: ViewModifier {
    let props: AgentBindingProps
    @State private var isRegistered = false

    public func body(content: Content) -> some View {
        content
            .accessibilityIdentifier(props.testID)
            .background(
                ScrollViewIntrospector(testID: props.testID, scrollViewProxy: props.scrollViewProxy)
                    .frame(width: 0, height: 0)
            )
            .onAppear {
                registerNode()
            }
            .onDisappear {
                unregisterNode()
            }
    }

    private func registerNode() {
        let node = AgentNode(
            view: nil,
            onTap: props.onTap,
            onLongPress: props.onLongPress,
            onChangeText: props.onChangeText,
            onSwipe: props.onSwipe,
            scrollViewProxy: props.scrollViewProxy
        )
        AgentRegistry.shared.register(testID: props.testID, node: node)
        isRegistered = true
    }

    private func unregisterNode() {
        if isRegistered {
            AgentRegistry.shared.unregister(testID: props.testID)
            isRegistered = false
        }
    }
}

// MARK: - ScrollView Introspector

#if canImport(UIKit)
struct ScrollViewIntrospector: UIViewRepresentable {
    let testID: String
    let scrollViewProxy: Any?

    func makeUIView(context: Context) -> IntrospectionUIView {
        let view = IntrospectionUIView()
        view.testID = testID
        view.scrollViewProxy = scrollViewProxy
        return view
    }

    func updateUIView(_ uiView: IntrospectionUIView, context: Context) {
        uiView.testID = testID
        uiView.scrollViewProxy = scrollViewProxy
    }

    class IntrospectionUIView: UIView {
        var testID: String?
        var scrollViewProxy: Any?

        override func didMoveToWindow() {
            super.didMoveToWindow()

            guard let testID = testID else { return }

            // First, set accessibilityIdentifier on the immediate parent view
            // This ensures the testID propagates to the UIKit layer for all views
            DispatchQueue.main.async {
                self.setAccessibilityOnParent(testID: testID)
            }

            // If there's a scrollViewProxy, also find and configure the ScrollView
            if scrollViewProxy != nil {
                // Find the UIScrollView in the parent hierarchy
                // Use a small delay to allow the view hierarchy to fully layout
                DispatchQueue.main.async {
                    self.attemptToFindScrollView(testID: testID, retryCount: 0)
                }
            }
        }

        private func setAccessibilityOnParent(testID: String) {
            // Set accessibilityIdentifier on the parent view to ensure
            // the testID is available in the UIKit hierarchy
            if let parent = self.superview {
                parent.accessibilityIdentifier = testID
            }
        }
        
        private func attemptToFindScrollView(testID: String, retryCount: Int) {
            if let scrollView = self.findImmediateScrollView() {
                // IMPORTANT: Manually set the accessibilityIdentifier on the UIScrollView
                // This allows our hierarchy search to find it later
                scrollView.accessibilityIdentifier = testID

                // Update the node with the UIScrollView reference
                var node = AgentRegistry.shared.getNode(testID: testID) ?? AgentNode(
                    view: nil,
                    onTap: nil,
                    onLongPress: nil,
                    onChangeText: nil,
                    onSwipe: nil,
                    scrollViewProxy: self.scrollViewProxy
                )
                node.view = scrollView
                AgentRegistry.shared.register(testID: testID, node: node)
            } else if retryCount < 2 {
                // Retry after a short delay to allow view hierarchy to settle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.attemptToFindScrollView(testID: testID, retryCount: retryCount + 1)
                }
            }
        }

        private func findImmediateScrollView() -> UIScrollView? {
            // Strategy: First search siblings and nearby views for a ScrollView,
            // then search upward in parent hierarchy
            // This handles SwiftUI's UIKit rendering where ScrollViews might be siblings
            
            // First, try searching siblings and nearby views
            if let scrollView = findScrollViewInSiblings() {
                return scrollView
            }
            
            // Second, try searching parent's siblings (the introspection view might be at a different level)
            if let scrollView = findScrollViewInParentsSiblings() {
                return scrollView
            }
            
            // Third, try comprehensive window search
            if let scrollView = findScrollViewInEntireWindow() {
                return scrollView
            }
            
            // Final fallback: search upward in parent hierarchy
            return findScrollViewInParents()
        }
        
        private func findScrollViewInSiblings() -> UIScrollView? {
            // Search in siblings and nearby views for a UIScrollView
            // This often works better for SwiftUI -> UIKit rendering
            
            guard let parent = self.superview else { return nil }
            
            // Use parent's frame for overlap calculation since introspection view is 0x0
            // The parent view typically represents the actual SwiftUI ScrollView content
            let referenceFrame = parent.convert(parent.bounds, to: nil)
            
            var candidates: [(scrollView: UIScrollView, area: CGFloat, frameOverlap: CGFloat)] = []
            
            // Recursively search for UIScrollViews in sibling tree
            for sibling in parent.subviews {
                findScrollViewsRecursive(in: sibling, selfFrame: referenceFrame, candidates: &candidates, depth: 0, maxDepth: 3)
            }
            
            // Filter out candidates with no frame overlap (introspection view should be within or near the ScrollView)
            let validCandidates = candidates.filter { $0.frameOverlap > 0.0 }
            
            if validCandidates.isEmpty {
                // If no overlapping candidates, fall back to smallest area
                if let smallest = candidates.min(by: { $0.area < $1.area }) {
                    return smallest.scrollView
                }
                return nil
            }
            
            // Prefer the ScrollView with best overlap score, then smallest area as tiebreaker
            if let best = validCandidates.max(by: { 
                if abs($0.frameOverlap - $1.frameOverlap) < 0.01 {
                    // Similar overlap, prefer smaller area
                    return $0.area > $1.area
                }
                return $0.frameOverlap < $1.frameOverlap
            }) {
                return best.scrollView
            }
            
            return nil
        }
        
        private func findScrollViewsRecursive(
            in view: UIView, 
            selfFrame: CGRect, 
            candidates: inout [(scrollView: UIScrollView, area: CGFloat, frameOverlap: CGFloat)],
            depth: Int,
            maxDepth: Int
        ) {
            if depth > maxDepth {
                return
            }
            
            // Check if this view is a UIScrollView
            if let scrollView = view as? UIScrollView {
                // Skip if this ScrollView is already assigned to a different testID
                if let existingID = scrollView.accessibilityIdentifier,
                   !existingID.isEmpty,
                   existingID != self.testID {
                    return
                }
                
                let area = scrollView.bounds.width * scrollView.bounds.height
                let scrollViewFrameInWindow = scrollView.convert(scrollView.bounds, to: nil)
                let overlap = frameOverlapScore(selfFrame, scrollViewFrameInWindow)
                candidates.append((scrollView, area, overlap))
            }
            
            // Recursively search subviews
            for subview in view.subviews {
                findScrollViewsRecursive(in: subview, selfFrame: selfFrame, candidates: &candidates, depth: depth + 1, maxDepth: maxDepth)
            }
        }
        
        private func frameOverlapScore(_ frame1: CGRect, _ frame2: CGRect) -> CGFloat {
            // Calculate how much frame1 overlaps with frame2
            // Returns a score from 0.0 (no overlap) to 1.0 (frame1 completely within frame2)
            
            let intersection = frame1.intersection(frame2)
            if intersection.isNull {
                return 0.0
            }
            
            // Calculate what percentage of frame1 is inside frame2
            let intersectionArea = intersection.width * intersection.height
            let frame1Area = frame1.width * frame1.height
            
            if frame1Area <= 0 {
                return 0.0
            }
            
            return intersectionArea / frame1Area
        }
        
        private func findScrollViewInParentsSiblings() -> UIScrollView? {
            // Search in parent's siblings and their children
            // Sometimes SwiftUI renders the introspection view at a different hierarchy level
            // We search through multiple levels of ancestors' siblings
            
            guard let firstParent = self.superview else { return nil }
            
            // Use parent's frame for overlap calculation since introspection view is 0x0
            let referenceFrame = firstParent.convert(firstParent.bounds, to: nil)
            
            var candidates: [(scrollView: UIScrollView, area: CGFloat, frameOverlap: CGFloat)] = []
            
            // Search through multiple levels of the parent hierarchy
            var currentParent: UIView? = firstParent
            var level = 0
            let maxLevels = 5
            
            while currentParent != nil && level < maxLevels {
                if let grandparent = currentParent?.superview {
                    // Search in this ancestor's siblings
                    for sibling in grandparent.subviews where sibling !== currentParent {
                        findScrollViewsRecursive(in: sibling, selfFrame: referenceFrame, candidates: &candidates, depth: 0, maxDepth: 4)
                    }
                }
                
                currentParent = currentParent?.superview
                level += 1
            }
            
            let validCandidates = candidates.filter { $0.frameOverlap > 0.0 }
            
            if validCandidates.isEmpty {
                return nil
            }
            
            if let best = validCandidates.max(by: { 
                if abs($0.frameOverlap - $1.frameOverlap) < 0.01 {
                    return $0.area > $1.area
                }
                return $0.frameOverlap < $1.frameOverlap
            }) {
                return best.scrollView
            }
            
            return nil
        }
        
        private func findScrollViewInEntireWindow() -> UIScrollView? {
            // Comprehensive search of ALL UIScrollViews in the window
            // Use this when sibling searches fail
            
            guard let window = self.window,
                  let parent = self.superview else { return nil }
            
            let referenceFrame = parent.convert(parent.bounds, to: nil)
            
            // Get introspection view position for proximity matching
            let introspectionPosition = self.convert(CGPoint(x: 0, y: 0), to: nil)
            
            var candidates: [(scrollView: UIScrollView, area: CGFloat, frameOverlap: CGFloat)] = []
            
            // Find all ScrollViews in window
            findAllScrollViewsInWindow(window, referenceFrame: referenceFrame, candidates: &candidates)
            
            // If reference frame has no area (0x0), use position proximity instead of overlap
            let hasReferenceArea = referenceFrame.width > 0 && referenceFrame.height > 0
            
            if !hasReferenceArea {
                // Filter out the main window scroll view (usually the largest)
                let nonMainScrollViews = candidates.filter { $0.area < 300000 }
                
                if nonMainScrollViews.isEmpty {
                    return nil
                }
                
                // Find the closest ScrollView by position
                let candidatesWithDistance = nonMainScrollViews.map { candidate -> (scrollView: UIScrollView, area: CGFloat, distance: CGFloat) in
                    let frame = candidate.scrollView.convert(candidate.scrollView.bounds, to: nil)
                    let distance = sqrt(pow(frame.origin.x - introspectionPosition.x, 2) + pow(frame.origin.y - introspectionPosition.y, 2))
                    return (candidate.scrollView, candidate.area, distance)
                }
                
                // Sort by distance (closest first), then by smallest area as tiebreaker
                if let closest = candidatesWithDistance.min(by: { 
                    if abs($0.distance - $1.distance) < 50 { // Within 50 points, prefer smaller area
                        return $0.area < $1.area
                    }
                    return $0.distance < $1.distance
                }) {
                    return closest.scrollView
                }
                
                return nil
            }
            
            // Original overlap-based logic for when reference frame has area
            let validCandidates = candidates.filter { $0.frameOverlap > 0.0 }
            
            if validCandidates.isEmpty {
                return nil
            }
            
            // Prefer ScrollView with best overlap, smallest area
            if let best = validCandidates.max(by: { 
                if abs($0.frameOverlap - $1.frameOverlap) < 0.01 {
                    return $0.area > $1.area
                }
                return $0.frameOverlap < $1.frameOverlap
            }) {
                return best.scrollView
            }
            
            return nil
        }
        
        private func findAllScrollViewsInWindow(
            _ view: UIView,
            referenceFrame: CGRect,
            candidates: inout [(scrollView: UIScrollView, area: CGFloat, frameOverlap: CGFloat)]
        ) {
            if let scrollView = view as? UIScrollView {
                // Skip if already assigned to a different testID
                if let existingID = scrollView.accessibilityIdentifier,
                   !existingID.isEmpty,
                   existingID != self.testID {
                    return
                }
                
                let area = scrollView.bounds.width * scrollView.bounds.height
                let scrollViewFrameInWindow = scrollView.convert(scrollView.bounds, to: nil)
                let overlap = frameOverlapScore(referenceFrame, scrollViewFrameInWindow)
                candidates.append((scrollView, area, overlap))
            }
            
            // Recursively search subviews
            for subview in view.subviews {
                findAllScrollViewsInWindow(subview, referenceFrame: referenceFrame, candidates: &candidates)
            }
        }
        
        private func findScrollViewInParents() -> UIScrollView? {
            // Find ALL parent ScrollViews, then pick the smallest one (innermost)
            // This prevents capturing outer container ScrollViews

            var scrollViews: [(scrollView: UIScrollView, depth: Int, area: CGFloat)] = []
            var current: UIView? = self.superview
            var depth = 0
            let maxDepth = 10

            while current != nil && depth < maxDepth {
                if let scrollView = current as? UIScrollView {
                    let area = scrollView.bounds.width * scrollView.bounds.height
                    scrollViews.append((scrollView, depth, area))
                }
                current = current?.superview
                depth += 1
            }

            // Return the smallest ScrollView (by area) - this is the innermost one
            if let smallest = scrollViews.min(by: { $0.area < $1.area }) {
                return smallest.scrollView
            }

            return nil
        }
    }
}
#else
struct ScrollViewIntrospector: View {
    let testID: String
    let scrollViewProxy: Any?

    var body: some View {
        EmptyView()
    }
}
#endif

// MARK: - View Extension

public extension View {
    /// Adds agent binding capabilities to a view, enabling it to be controlled by the agent system
    ///
    /// - Parameters:
    ///   - testID: Unique identifier for this view
    ///   - onTap: Optional closure to handle tap actions
    ///   - onLongPress: Optional closure to handle long press actions
    ///   - onChangeText: Optional closure to handle text input changes
    ///   - onSwipe: Optional closure to handle swipe gestures (direction, velocity)
    ///   - scrollViewProxy: Optional ScrollViewProxy for programmatic scrolling
    /// - Returns: Modified view with agent binding capabilities
    func agentBinding(
        testID: String,
        onTap: (() -> Void)? = nil,
        onLongPress: (() -> Void)? = nil,
        onChangeText: ((String) -> Void)? = nil,
        onSwipe: ((String, String) -> Void)? = nil,
        scrollViewProxy: Any? = nil
    ) -> some View {
        let props = AgentBindingProps(
            testID: testID,
            onTap: onTap,
            onLongPress: onLongPress,
            onChangeText: onChangeText,
            onSwipe: onSwipe,
            scrollViewProxy: scrollViewProxy
        )
        return self.modifier(AgentBindingModifier(props: props))
    }
}

// MARK: - Convenience Button Wrapper

public struct AgentButton<Label: View>: View {
    let testID: String
    let action: () -> Void
    let label: () -> Label

    public init(testID: String, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.testID = testID
        self.action = action
        self.label = label
    }

    public var body: some View {
        Button(action: action) {
            label()
        }
        .agentBinding(testID: testID, onTap: action)
    }
}

// MARK: - Convenience TextField Wrapper

public struct AgentTextField: View {
    let testID: String
    let placeholder: String
    @Binding var text: String

    public init(testID: String, placeholder: String, text: Binding<String>) {
        self.testID = testID
        self.placeholder = placeholder
        self._text = text
    }

    public var body: some View {
        TextField(placeholder, text: $text)
            .agentBinding(testID: testID, onChangeText: { newValue in
                text = newValue
            })
    }
}

// MARK: - Example Usage

/*

 Usage examples:

 1. Using the modifier directly on any view:

 Button("Click Me") {
     print("Button clicked")
 }
 .agentBinding(testID: "my-button", onTap: {
     print("Button clicked via agent")
 })

 2. Using the AgentButton wrapper:

 AgentButton(testID: "my-button") {
     print("Button clicked")
 } label: {
     Text("Click Me")
 }

 3. Using the AgentTextField wrapper:

 @State private var inputText = ""

 AgentTextField(testID: "my-input", placeholder: "Enter text", text: $inputText)

 4. Using with other gestures:

 Text("Long press me")
     .agentBinding(
         testID: "long-press-text",
         onTap: { print("Tapped") },
         onLongPress: { print("Long pressed") }
     )
     .onTapGesture {
         print("Actual tap")
     }
     .onLongPressGesture {
         print("Actual long press")
     }

 */
