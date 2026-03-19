/** @type {import('tailwindcss').Config} */
module.exports = {
  future: {
    // Fix iOS double-tap: hover: variants only apply on devices that actually support hover (mouse/trackpad).
    // On touch screens, hover states never activate on first tap → navigation fires immediately.
    hoverOnlyWhenSupported: true,
  },
  darkMode: 'class', // Habilitar modo oscuro basado en clase
  content: ['./index.html', './src/**/*.{js,ts,jsx,tsx}'],
  theme: {
    extend: {
      animation: {
        fadeIn: 'fadeIn 0.3s ease-out',
      },
      fontFamily: {
        sans: ['Inter', 'sans-serif'],
        title: ['Space Grotesk', 'sans-serif'],
      },
      letterSpacing: {
        tightest: '-0.02em',
      },
      // Optimizaciones de transiciones
      transitionDuration: {
        DEFAULT: '150ms',
      },
      transitionTimingFunction: {
        DEFAULT: 'cubic-bezier(0.4, 0, 0.2, 1)',
      },
    },
  },
  // Optimizaciones de Tailwind
  corePlugins: {
    // Desactivar plugins no usados
    preflight: true,
  },
  // Optimizar el purge/content
  safelist: [
    // Clases dinámicas que siempre deben incluirse
    'animate-spin',
    'animate-fadeIn',
  ],
  plugins: [],
}
