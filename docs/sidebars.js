/**
 * Creating a sidebar enables you to:
 - create an ordered group of docs
 - render a set of docs in the sidebar
 - provide next/previous navigation

 The sidebars can be generated from the filesystem, or explicitly defined here.

 Create as many sidebars as you want.
 */

// @ts-check

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  // By default, Docusaurus generates a sidebar from the docs folder structure
  tutorialSidebar: [
    'intro',
    {
      label: 'Getting Started',
      items: [
        'getting-started/installation',
        'getting-started/first-widget',
        'getting-started/testing',
      ],
    },
    {
      label: 'Widget SDK',
      items: [
        'widget-sdk/overview',
        'widget-sdk/manifest',
        'widget-sdk/lifecycle',
      ],
    },
    {
      label: 'SDK Reference',
      items: [
        'sdk-reference/hooks',
        'sdk-reference/host-api',
        'sdk-reference/types',
        'sdk-reference/utilities',
      ],
    },
    {
      label: 'Widget Development',
      items: [
        'widget-development/dev-simulator',
        'widget-development/testing-widgets',
        'widget-development/packaging-distribution',
        'widget-development/best-practices',
      ],
    },
    {
      label: 'Examples',
      items: [
        'examples/hello-world',
        'examples/counter-widget',
        'examples/tool-widget',
        'examples/storage-widget',
      ],
    },
    'troubleshooting',
  ],
};

export default sidebars;
