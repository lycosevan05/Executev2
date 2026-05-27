/** @type {import('tailwindcss').Config} */
module.exports = {
    darkMode: ["class"],
    content: ["./index.html", "./src/**/*.{ts,tsx,js,jsx}"],
  theme: {
  	extend: {
  		borderRadius: {
  			lg: 'var(--radius)',
  			md: 'calc(var(--radius) - 2px)',
  			sm: 'calc(var(--radius) - 4px)',
        xl: '1.25rem',
        '2xl': '1.5rem',
        '3xl': '2rem',
  		},
  		colors: {
  			background: 'hsl(var(--background))',
  			foreground: 'hsl(var(--foreground))',
  			card: {
  				DEFAULT: 'hsl(var(--card))',
  				foreground: 'hsl(var(--card-foreground))'
  			},
  			popover: {
  				DEFAULT: 'hsl(var(--popover))',
  				foreground: 'hsl(var(--popover-foreground))'
  			},
  			primary: {
  				DEFAULT: 'hsl(var(--primary))',
  				foreground: 'hsl(var(--primary-foreground))'
  			},
  			secondary: {
  				DEFAULT: 'hsl(var(--secondary))',
  				foreground: 'hsl(var(--secondary-foreground))'
  			},
  			muted: {
  				DEFAULT: 'hsl(var(--muted))',
  				foreground: 'hsl(var(--muted-foreground))'
  			},
  			accent: {
  				DEFAULT: 'hsl(var(--accent))',
  				foreground: 'hsl(var(--accent-foreground))'
  			},
  			destructive: {
  				DEFAULT: 'hsl(var(--destructive))',
  				foreground: 'hsl(var(--destructive-foreground))'
  			},
  			border: 'hsl(var(--border))',
  			input: 'hsl(var(--input))',
  			ring: 'hsl(var(--ring))',
  			chart: {
  				'1': 'hsl(var(--chart-1))',
  				'2': 'hsl(var(--chart-2))',
  				'3': 'hsl(var(--chart-3))',
  				'4': 'hsl(var(--chart-4))',
  				'5': 'hsl(var(--chart-5))'
  			},
        parchment: '#f6f2e8',
        'parchment-light': '#fbf8f1',
        'parchment-card': '#f2efe7',
        chartreuse: '#c8e000',
        'chartreuse-light': '#d4ef1f',
        'chartreuse-dark': '#8ea400',
        charcoal: '#141613',
        olive: '#5d635d',
        mist: '#91968e',
        'border-warm': '#e8e1d4',
        'border-warm-dark': '#d9d1c2',
        // legacy aliases kept for any missed references
        obsidian: '#f6f2e8',
        'obsidian-glass': '#fbf8f1',
        'electric-oxygen': '#c8e000',
        'neon-ember': '#b05a3a',
        'hyper-lime': '#8ea400',
        'ice-white': '#141613',
        'slate-mist': '#91968e',
  		},
      fontFamily: {
        inter: ['Inter', '-apple-system', 'BlinkMacSystemFont', 'sans-serif'],
      },
      fontSize: {
        'hero': ['2.5rem', { letterSpacing: '-0.04em', lineHeight: '1.1' }],
        'display': ['3.5rem', { letterSpacing: '-0.04em', lineHeight: '1.05' }],
      },
  		keyframes: {
  			'accordion-down': {
  				from: { height: '0' },
  				to: { height: 'var(--radix-accordion-content-height)' }
  			},
  			'accordion-up': {
  				from: { height: 'var(--radix-accordion-content-height)' },
  				to: { height: '0' }
  			},
        'fade-up': {
          from: { opacity: '0', transform: 'translateY(20px)' },
          to: { opacity: '1', transform: 'translateY(0)' }
        },
        'fade-in': {
          from: { opacity: '0' },
          to: { opacity: '1' }
        },
        'scale-in': {
          from: { opacity: '0', transform: 'scale(0.95)' },
          to: { opacity: '1', transform: 'scale(1)' }
        }
  		},
  		animation: {
  			'accordion-down': 'accordion-down 0.2s ease-out',
  			'accordion-up': 'accordion-up 0.2s ease-out',
        'fade-up': 'fade-up 0.6s ease-out forwards',
        'fade-in': 'fade-in 0.4s ease-out forwards',
        'scale-in': 'scale-in 0.4s ease-out forwards',
  		},
      backgroundImage: {
        'gradient-radial': 'radial-gradient(var(--tw-gradient-stops))',
        'neural-gradient': 'linear-gradient(135deg, #050508 0%, #0a0a12 50%, #050508 100%)',
      },
      safelist: [
        'text-electric-oxygen', 'text-neon-ember', 'text-hyper-lime',
        'bg-electric-oxygen', 'bg-neon-ember', 'bg-hyper-lime',
        'border-electric-oxygen', 'border-neon-ember', 'border-hyper-lime',
        'glow-cyan', 'glow-ember', 'glow-lime',
      ]
  	}
  },
  plugins: [require("tailwindcss-animate")],
  safelist: [
    'text-electric-oxygen', 'text-neon-ember', 'text-hyper-lime',
    'bg-electric-oxygen', 'bg-neon-ember', 'bg-hyper-lime',
    'border-electric-oxygen', 'border-neon-ember', 'border-hyper-lime',
  ]
}