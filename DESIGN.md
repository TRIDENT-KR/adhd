# Design System Document: Soft Minimalism for Cognitive Ease

## 1. Overview & Creative North Star
**Creative North Star: "The Guided Sanctuary"**

This design system is built to counteract the "noise" of ADHD. It moves beyond standard minimalism into a high-end, editorial experience where the interface feels like a living, breathing space rather than a digital tool. We reject the "grid-of-boxes" mentality in favor of **Organic Asymmetry**. 

To achieve a signature feel, we use ultra-wide margins, overlapping typographic elements, and a "voice-first" hierarchy. The layout should feel "airy" but grounded, using large-scale display type to anchor the user’s focus, while secondary information retreats into the background through lower-contrast tonal shifts.

---

## 2. Colors & Tonal Depth
Our palette is rooted in the earth. It is designed to lower heart rates and provide a stable foundation for a voice-based experience.

### The Palette
*   **Background (#F9F9F7):** Our primary canvas. It is a "warm paper" white that reduces eye strain.
*   **Primary (#934A2E):** A sophisticated terracotta. Use this sparingly for moments of high intent (the "Start Routine" button).
*   **Tertiary (#006A63):** A muted teal. Use this for "success" states or calming feedback loops during voice interaction.

### The "No-Line" Rule
**Explicit Instruction:** Designers are prohibited from using 1px solid borders for sectioning. 
Structure must be defined through:
1.  **Background Shifts:** Use `surface-container-low` (#F4F4F2) for a section resting on a `surface` (#F9F9F7) background.
2.  **Negative Space:** Use the Spacing Scale (specifically 10, 12, or 16) to create "islands" of content.

### The "Glass & Gradient" Rule
To add "soul" to the UI, avoid flat terracotta blocks for large CTAs. Use a subtle linear gradient from `primary` (#934A2E) to `primary-container` (#D27C5C) at a 135-degree angle. For floating voice-control bars, use `surface-lowest` with a 20px `backdrop-blur` and 80% opacity to create a "frosted glass" effect that feels premium and integrated.

---

## 3. Typography
We use a dual-font system to create a sophisticated, editorial rhythm.

*   **Display & Headlines (Manrope):** Chosen for its geometric but friendly curves. 
    *   *Rule:* All `display-lg` and `display-md` should have a `-2%` letter-spacing to feel "tight" and authoritative.
*   **Body & Labels (Inter):** Chosen for peak legibility. 
    *   *Rule:* All `body-lg` and `body-md` must have a `+0.02em` letter-spacing. This "breathing room" between characters is essential for users with ADHD to process text without feeling overwhelmed.

**Hierarchy as Identity:** Use `display-lg` (3.5rem) for the current step in a routine. Everything else on the screen should drop down to `title-sm` or `body-md` to ensure the user’s "Focus Point" is singular and unmistakable.

---

## 4. Elevation & Depth
In this system, depth is "soft." We do not use traditional shadows that suggest a harsh light source.

*   **The Layering Principle:** Stack `surface-container` tiers. 
    *   *Level 0:* `surface` (The App Background)
    *   *Level 1:* `surface-container-low` (A section or "tray")
    *   *Level 2:* `surface-container-lowest` (A card sitting inside that tray)
*   **Ambient Shadows:** If an element must "float" (like a voice-active button), use a shadow color of `#54433D` (on-surface-variant) at **5% opacity** with a **40px blur** and **10px Y-offset**. It should look like a glow, not a shadow.
*   **The Ghost Border:** For input fields, use `outline-variant` at **20% opacity**. It should be barely visible—a "whisper" of a boundary.

---

## 5. Components

### Buttons
*   **Primary:** Rounded `full` (9999px), using the Terracotta gradient. Padding: `1.2rem` (top/bottom) by `2.75rem` (left/right).
*   **Secondary:** No background. Use `title-md` typography with a `primary` color. No border.
*   **Interaction:** On press, the button should scale down to `0.98` to provide tactile, "squishy" feedback.

### Cards & Lists
*   **The Divider Ban:** Never use lines. Use `surface-container-low` for card backgrounds and `spacing-6` (2rem) as the gap between them.
*   **Corner Radius:** Cards use `xl` (3rem) for a friendly, pill-like softness.

### The "Voice Pulse" (Custom Component)
A central, circular element for voice interaction. Use `primary-fixed-dim` with a `backdrop-blur`. Apply a slow, 4-second "breather" animation (scaling between 1.0 and 1.1) to mimic human lung rhythm.

### Input Fields
*   Minimalist styling. Use `body-lg` for text. The label should float above in `label-sm` with `on-surface-variant`. No background color; use a "Ghost Border" bottom-line only.

---

## 6. Do’s and Don’ts

### Do:
*   **Embrace the Void:** If a screen only has one sentence and one button, leave it that way. Whitespace is a functional feature for ADHD focus.
*   **Use Intentional Asymmetry:** Align the header to the left and the primary CTA to the right to create a "path" for the eye.
*   **Soft Transitions:** All state changes (hover, active, screen transitions) should have a duration of at least `300ms` with a `cubic-bezier(0.4, 0, 0.2, 1)` easing.

### Don't:
*   **No "Hard" Grays:** Never use #000000 or standard neutral grays. Use our tinted `on-surface` (#1A1C1B) to keep the palette warm.
*   **No 1px Lines:** Do not use dividers to separate routine steps. Use vertical spacing (`spacing-12`).
*   **No Information Density:** Never put more than three actionable items on a single screen. If a routine has more, use a progressive disclosure pattern (one step at a time).