# ComfyUI graph renderer

This application bundles the unmodified UMD build and CSS of
`@comfyorg/litegraph` **0.17.2**, published by Comfy-Org (MIT).

- Source: https://github.com/Comfy-Org/litegraph.js
- Distribution: https://registry.npmjs.org/@comfyorg/litegraph/-/litegraph-0.17.2.tgz
- License: [LICENSE](LICENSE)

This is the classic ComfyUI Canvas2D node engine. Its source was merged into
ComfyUI_frontend in August 2025. It is not the complete ComfyUI application or
the newer Nodes 2.0 interface. The pinned renderer runs offline; no ComfyUI
server, model assets, CDN, or user-code JavaScript execution is involved.

`model.js` adapts Python AST nodes to named LiteGraph ports and groups.
`canvas.js` supplies application-specific read-only values and source navigation.
Python control flow remains authoritative, with separate execution and data
ports, branch labels, loops, exceptions, and calls inspired by UE Blueprints.
