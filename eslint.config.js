import { createRequire } from "node:module";
import globals from "globals";
import pluginJs from "@eslint/js";
import pluginReactHooks from "eslint-plugin-react-hooks";

const require = createRequire(import.meta.url);
const pluginReact = {
  rules: {
    "jsx-uses-vars": require("eslint-plugin-react/lib/rules/jsx-uses-vars"),
    "jsx-uses-react": require("eslint-plugin-react/lib/rules/jsx-uses-react"),
  },
};

export default [
  {
    ignores: ["dist/**", "node_modules/**", "ios/**"],
  },
  {
    files: [
      "src/components/**/*.{js,mjs,cjs,jsx}",
      "src/pages/**/*.{js,mjs,cjs,jsx}",
      "src/Layout.jsx",
    ],
    ignores: ["src/lib/**/*", "src/components/ui/**/*"],
    languageOptions: {
      globals: globals.browser,
      parserOptions: {
        ecmaVersion: 2022,
        sourceType: "module",
        ecmaFeatures: {
          jsx: true,
        },
      },
    },
    plugins: {
      react: pluginReact,
      "react-hooks": pluginReactHooks,
    },
    rules: {
      ...pluginJs.configs.recommended.rules,
      "react/jsx-uses-vars": "error",
      "react/jsx-uses-react": "off",
      "no-unused-vars": [
        "warn",
        {
          vars: "all",
          varsIgnorePattern: "^_",
          args: "after-used",
          argsIgnorePattern: "^_",
          ignoreRestSiblings: true,
        },
      ],
      "react-hooks/rules-of-hooks": "error",
    },
  },
];
