---
name: VitalSense
colors:
  surface: '#f9f9ff'
  surface-dim: '#cfdaf2'
  surface-bright: '#f9f9ff'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#f0f3ff'
  surface-container: '#e7eeff'
  surface-container-high: '#dee8ff'
  surface-container-highest: '#d8e3fb'
  on-surface: '#111c2d'
  on-surface-variant: '#41474e'
  inverse-surface: '#263143'
  inverse-on-surface: '#ecf1ff'
  outline: '#71787f'
  outline-variant: '#c1c7cf'
  surface-tint: '#21638d'
  primary: '#21638d'
  on-primary: '#ffffff'
  primary-container: '#90caf9'
  on-primary-container: '#08557e'
  inverse-primary: '#93cdfc'
  secondary: '#006398'
  on-secondary: '#ffffff'
  secondary-container: '#6cbdfe'
  on-secondary-container: '#004b75'
  tertiary: '#006d36'
  on-tertiary: '#ffffff'
  tertiary-container: '#4ade80'
  on-tertiary-container: '#005e2d'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#cbe6ff'
  primary-fixed-dim: '#93cdfc'
  on-primary-fixed: '#001e30'
  on-primary-fixed-variant: '#004b71'
  secondary-fixed: '#cde5ff'
  secondary-fixed-dim: '#94ccff'
  on-secondary-fixed: '#001d32'
  on-secondary-fixed-variant: '#004b74'
  tertiary-fixed: '#6dfe9c'
  tertiary-fixed-dim: '#4de082'
  on-tertiary-fixed: '#00210c'
  on-tertiary-fixed-variant: '#005227'
  background: '#f9f9ff'
  on-background: '#111c2d'
  surface-variant: '#d8e3fb'
typography:
  display-metrics:
    fontFamily: Inter
    fontSize: 48px
    fontWeight: '700'
    lineHeight: 56px
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: Inter
    fontSize: 32px
    fontWeight: '700'
    lineHeight: 40px
    letterSpacing: -0.01em
  headline-lg-mobile:
    fontFamily: Inter
    fontSize: 24px
    fontWeight: '700'
    lineHeight: 32px
  headline-md:
    fontFamily: Inter
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
  body-lg:
    fontFamily: Inter
    fontSize: 18px
    fontWeight: '400'
    lineHeight: 28px
  body-md:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  label-caps:
    fontFamily: Inter
    fontSize: 12px
    fontWeight: '600'
    lineHeight: 16px
    letterSpacing: 0.05em
  data-tabular:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '500'
    lineHeight: 20px
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  base: 8px
  xs: 4px
  sm: 12px
  md: 24px
  lg: 40px
  xl: 64px
  gutter: 24px
  margin-mobile: 16px
  margin-desktop: 48px
---

## Brand & Style
The design system is centered on the concept of "Clinical Clarity"—a premium, medical-grade aesthetic that prioritizes the cognitive load of caregivers. The brand personality is professional, dependable, and calm, evoking a sense of precision without the coldness of traditional hospital software. 

The style utilizes a **Modern Corporate** approach with **Minimalist** influences. It relies on generous whitespace (an "airy" aesthetic) to separate critical data points, ensuring that life-saving information is never obscured by visual clutter. Depth is achieved through soft tonal layering rather than aggressive lines, creating a UI that feels approachable yet authoritative.

## Colors
The palette is engineered for high legibility and emotional stability. The primary blue is soft to reduce eye strain during long shifts, while the deeper slate neutral ensures text meets AA/AAA accessibility standards for contrast.

- **Primary (#90CAF9):** Used for primary actions, branding, and high-level summaries.
- **Secondary/Accent (#64B5F6):** Reserved for interactive states (hover, active) and key focus indicators.
- **Status-Live (#4ADE80):** Specifically for real-time data streams and "Healthy" status indicators.
- **Surface (#F8FAFC):** Used for card backgrounds to provide a subtle distinction from the pure white application background.

## Typography
This design system utilizes **Inter** for its exceptional legibility and comprehensive support for tabular figures. 

The typography hierarchy is dominated by "Display Metrics," designed for rapid scanning of vital signs from a distance. For all numerical data, use `font-variant-numeric: tabular-nums` to ensure that columns of numbers align perfectly, which is critical for medical data comparison. Headers should be bold and professional, using tight letter-spacing to maintain a structured feel.

## Layout & Spacing
The layout follows a **Fluid Grid** model with a max-width of 1440px for desktop dashboards. 

- **Desktop:** 12-column grid, 24px gutters, and 48px outer margins.
- **Tablet:** 8-column grid, 24px gutters, 24px margins.
- **Mobile:** 4-column grid, 16px gutters, 16px margins.

The spacing rhythm is built on an 8px base unit. Use "lg" (40px) or "xl" (64px) spacing for vertical section separation to maintain the "airy" feel. Avoid tight clusters of information; if two components feel crowded, default to the larger spacing increment.

## Elevation & Depth
In this design system, depth is used to communicate "clickability" and "importance." 

- **Level 0 (Background):** Pure white (#FFFFFF).
- **Level 1 (Cards/Surface):** Very light gray (#F8FAFC) with a subtle 1px border (#E2E8F0) to define boundaries without heavy visual weight.
- **Level 2 (Interaction/Popovers):** Uses soft, diffused ambient shadows: `0px 10px 15px -3px rgba(30, 41, 59, 0.05)`.
- **Active Elevation:** When a patient card or data metric is selected, use a 2px stroke of the Primary color instead of a shadow to maintain a clean, clinical profile.

## Shapes
The shape language is purposefully soft to offset the high-stakes nature of medical monitoring. 

- **Standard Elements:** Buttons and input fields use a 12px (0.75rem) radius.
- **Container Elements:** Cards, patient profile modules, and dashboard widgets use a **24px (1.5rem)** radius (`rounded-xl`).
- **Interactive Indicators:** Small badges or status dots (like the Live indicator) should be fully pill-shaped.

## Components
### Buttons
- **Primary:** Solid Primary blue with white text. Rounded 12px.
- **Secondary:** Surface gray background with Neutral slate text. 1px subtle border.
- **Critical:** Reserved for alerts; use a soft red tint with bold text.

### Cards (Vital Modules)
Cards are the core of this design system. They must use the 24px corner radius and #F8FAFC background. Content should have 24px internal padding. Title of the metric (e.g., "Heart Rate") should use `label-caps`.

### Data Tables
Tables should avoid vertical dividers. Use horizontal lines in #F1F5F9. Row height should be generous (min 56px) to allow for easy touch-selection on tablets.

### Live Indicators
The "LIVE" status indicator is a pill-shaped badge using Status-Live (#4ADE80) with a subtle pulse animation. It should always be accompanied by the label "LIVE" in `label-caps` for clarity.

### Inputs
Search and patient filters use a soft 12px radius, a 1px border in #E2E8F0, and an inset search icon. Focus state transitions the border to Primary blue with a 3px soft outer glow.