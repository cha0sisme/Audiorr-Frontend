import type React from 'react'

/**
 * Apple Music-style spring press animation for buttons.
 *
 * Spread onto any <button> element:
 *   <button {...springPress} onClick={...}>
 *
 * Behaviour:
 *   pointerDown  → instantly compress to 0.92
 *   pointerUp    → spring release: 0.92 → 1.08 → 1.0  (cubic-bezier overshoot)
 *   pointerLeave → soft reset to 1.0 (finger/cursor moved away before release)
 */
export const springPress: Pick<
  React.ButtonHTMLAttributes<HTMLButtonElement>,
  'onPointerDown' | 'onPointerUp' | 'onPointerLeave'
> = {
  onPointerDown(e) {
    const el = e.currentTarget
    el.getAnimations().forEach(a => a.cancel())
    el.animate(
      [{ transform: 'scale(1)' }, { transform: 'scale(0.92)' }],
      { duration: 100, easing: 'ease-out', fill: 'forwards' }
    )
  },
  onPointerUp(e) {
    const el = e.currentTarget
    el.getAnimations().forEach(a => a.cancel())
    el.animate(
      [
        { transform: 'scale(0.92)' },
        { transform: 'scale(1.08)' },
        { transform: 'scale(1)' },
      ],
      { duration: 380, easing: 'cubic-bezier(0.34, 1.56, 0.64, 1)' }
    )
  },
  onPointerLeave(e) {
    const el = e.currentTarget
    el.getAnimations().forEach(a => a.cancel())
    el.animate(
      [{ transform: 'scale(0.92)' }, { transform: 'scale(1)' }],
      { duration: 180, easing: 'ease-out' }
    )
  },
}
