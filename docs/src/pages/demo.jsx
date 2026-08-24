import React from 'react';
import Layout from '@theme/Layout';
import useBaseUrl from '@docusaurus/useBaseUrl';

// The wasm chartplotter (bindings/wasm/demo.html), embedded full-bleed under
// the navbar. The app itself is staged by the docs workflow under
// static/demo-app/ — the engine wasm plus the demo page — so this page only
// frames it. Same origin, so drag-and-drop, the worker, and WebGPU all work
// inside the frame; allowFullScreen lets its ⛶ button work.
export default function Demo() {
  return (
    <Layout
      title="Live Demo"
      description="A chartplotter running in your browser: tile57 compiled to WebAssembly bakes S-57 charts and renders S-52 views, with no server."
      noFooter
    >
      <iframe
        src={useBaseUrl('/demo-app/')}
        title="tile57 wasm chartplotter"
        allowFullScreen
        style={{
          display: 'block',
          width: '100%',
          height: 'calc(100vh - var(--ifm-navbar-height))',
          border: 0,
        }}
      />
    </Layout>
  );
}
