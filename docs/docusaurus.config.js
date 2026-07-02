// @ts-check
import {themes as prismThemes} from 'prism-react-renderer';

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'tile57',
  tagline: '⚓ A high-performance, low-memory S-57 → MVT + S-52 style engine.',

  url: 'https://beetlebugorg.github.io',
  baseUrl: '/tile57/',

  organizationName: 'beetlebugorg',
  projectName: 'tile57',

  onBrokenLinks: 'warn',

  markdown: {
    hooks: {
      onBrokenMarkdownLinks: 'warn',
    },
  },

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          routeBasePath: '/',
          sidebarPath: './sidebars.js',
          editUrl:
            'https://github.com/beetlebugorg/tile57/tree/main/docs/',
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      navbar: {
        title: 'tile57',
        items: [
          {
            href: 'https://github.com/beetlebugorg/chartplotter-go',
            label: 'chartplotter-go',
            position: 'right',
          },
          {
            href: 'https://github.com/beetlebugorg/tile57',
            label: 'GitHub',
            position: 'right',
          },
        ],
      },
      footer: {
        style: 'dark',
        links: [
          {
            title: 'Docs',
            items: [
              {label: 'Introduction', to: '/'},
              {label: 'Installation', to: '/installation'},
              {label: 'C API', to: '/c-api'},
            ],
          },
          {
            title: 'More',
            items: [
              {
                label: 'GitHub',
                href: 'https://github.com/beetlebugorg/tile57',
              },
              {
                label: 'chartplotter-go (the chart-plotter app)',
                href: 'https://github.com/beetlebugorg/chartplotter-go',
              },
            ],
          },
        ],
        copyright: `Copyright © ${new Date().getFullYear()} Jeremy Collins.`,
      },
      prism: {
        theme: prismThemes.github,
        darkTheme: prismThemes.dracula,
        additionalLanguages: ['bash', 'json', 'c', 'zig'],
      },
    }),
};

export default config;
