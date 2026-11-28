# 路线列表顶栏与使用次数 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sticky route-list header showing imported route count and total route uses; persist `plannedRouteID` on saved workouts when a library route was selected.

**Architecture:** Extend `WorkoutRecord` with optional `plannedRouteID`. Set it in the phone finish path from `WorkoutDraft` + `savedRoutes`. Derive header counts from `importedRoutes` and workouts with non-nil `plannedRouteID`. Mirror records-list sticky chrome without the month title.

**Tech Stack:** SwiftUI, Shared `Models.swift`, phone `RoutesView` / `LiveWorkoutView`.

---

### Task 1: Persist plannedRouteID

**Files:**
- Modify: `codes/ios/Shared/Models.swift`
- Modify: `codes/ios/sky-wanderer/LiveWorkoutView.swift`
- Modify: `codes/ios/sky-wanderer/PlannedRouteProgress.swift` (helper)
- Test: `codes/ios/training-route-check/main.swift` (or small assert helpers)

- [ ] Add `plannedRouteID: String? = nil` + Codable
- [ ] Helper: library route id from draft, or nil for free / unknown / workout-as-plan
- [ ] On finish save, stamp `plannedRouteID` before `addWorkout`

### Task 2: Route list sticky header

**Files:**
- Modify: `codes/ios/sky-wanderer/RoutesView.swift`

- [ ] When routes non-empty: VStack with stats bar + scroll list
- [ ] Show `N 条路线` and `M 次使用`
- [ ] Empty state unchanged

### Task 3: Ship

- [ ] Commit, push, update PR #151
