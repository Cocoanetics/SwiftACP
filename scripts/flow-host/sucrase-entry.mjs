// The TypeScript compiler the flow host loads .ts flows with: sucrase, bundled — and its
// parser, which finds the `import.meta` a compiled CommonJS module still holds. The parser
// comes from the same (CommonJS) build `sucrase` resolves to, so it is bundled once.
export { transform } from "sucrase";
export { parse } from "sucrase/dist/parser/index.js";
export { TokenType } from "sucrase/dist/parser/tokenizer/types.js";
