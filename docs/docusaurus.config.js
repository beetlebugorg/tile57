// @ts-check
import {themes as prismThemes} from 'prism-react-renderer';

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'chartplotter-native',
  tagline: '⚓ Marine chart tiles, generated natively in Zig.',

  url: 'https://beetlebugorg.github.io',
  baseUrl: '/chartplotter-native/',

  organizationName: 'beetlebugorg',
  projectName: 'chartplotter-native',

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
            'https://github.com/beetlebugorg/chartplotter-native/tree/main/docs/',
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
        title: 'chartplotter-native',
        items: [
          {
            href: 'https://github.com/beetlebugorg/chartplotter',
            label: 'chartplotter-go',
            position: 'right',
          },
          {
            href: 'https://github.com/beetlebugorg/chartplotter-native',
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
                href: 'https://github.com/beetlebugorg/chartplotter-native',
              },
              {
                label: 'chartplotter-go (reference impl)',
                href: 'https://github.com/beetlebugorg/chartplotter',
              },
            ],
          },
        ],
        copyright: `Copyright © ${new Date().getFullYear()} Jeremy Collins.`,
      },
      prism: {
        theme: prismThemes.github,
        darkTheme: prismThemes.dracula,
        additionalLanguages: ['bash', 'json', 'c', 'cpp', 'zig', 'cmake'],
      },
    }),
};

export default config;
