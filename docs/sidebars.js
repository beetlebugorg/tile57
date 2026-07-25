// @ts-check

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  docs: [
    'intro',
    'installation',
    'getting-started',
    'cli',
    {
      type: 'category',
      label: 'Zig API',
      link: {type: 'doc', id: 'zig-api'},
      items: [
        'zig/errors-lifecycle',
        'zig/bake',
        'zig/render',
        'zig/compose',
        'zig/assets',
        'zig/style',
        'zig/low-level',
      ],
    },
    {
      type: 'category',
      label: 'C API',
      link: {type: 'doc', id: 'c-api'},
      items: [
        'api/errors-lifecycle',
        'api/bake',
        'api/render',
        'api/compose',
        'api/assets',
        'api/style',
      ],
    },
    'architecture',
    'rendering',
    'tile-schema',
    'limitations',
    'contributing',
  ],
};

export default sidebars;
