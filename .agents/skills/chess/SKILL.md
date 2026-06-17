```markdown
# chess Development Patterns

> Auto-generated skill from repository analysis

## Overview
This skill teaches you the development patterns and conventions used in the `chess` TypeScript codebase. It covers file organization, import/export styles, commit message practices, and testing patterns. By following this guide, you'll be able to contribute code that matches the project's established style and workflows.

## Coding Conventions

### File Naming
- Use **PascalCase** for file names.
  - Example: `ChessBoard.ts`, `GameLogic.ts`

### Import Style
- Use **relative imports** for modules within the project.
  - Example:
    ```typescript
    import { ChessBoard } from './ChessBoard';
    ```

### Export Style
- Use **named exports** for all modules.
  - Example:
    ```typescript
    export function calculateMove() { ... }
    export const PIECE_TYPES = ['pawn', 'knight', 'bishop', 'rook', 'queen', 'king'];
    ```

### Commit Messages
- Freeform commit messages, average length ~72 characters.
- No strict prefixes required, but keep messages clear and descriptive.
  - Example:  
    ```
    Fix bug in pawn promotion logic
    ```

## Workflows

### Adding a New Feature
**Trigger:** When implementing a new functionality.
**Command:** `/add-feature`

1. Create a new file using PascalCase (e.g., `NewFeature.ts`).
2. Write your feature using TypeScript, using named exports.
3. Import any dependencies using relative paths.
4. Add or update tests in a corresponding `*.test.*` file.
5. Commit your changes with a clear, descriptive message.

### Fixing a Bug
**Trigger:** When resolving a defect or issue.
**Command:** `/fix-bug`

1. Locate the relevant file(s) using PascalCase naming.
2. Make the necessary code changes.
3. Update or add tests to cover the bug fix.
4. Commit your changes with a message describing the fix.

### Writing Tests
**Trigger:** When adding or updating tests for a module.
**Command:** `/write-test`

1. Create or update a test file matching the pattern `*.test.*` (e.g., `ChessBoard.test.ts`).
2. Write tests for your module or feature.
3. Use the project's preferred (unknown) testing framework.
4. Run tests to ensure correctness.

## Testing Patterns

- Test files use the pattern `*.test.*` (e.g., `GameLogic.test.ts`).
- The specific testing framework is not detected; follow existing test examples.
- Place tests alongside or near the modules they cover.
- Ensure all new features and bug fixes are covered by corresponding tests.

## Commands
| Command      | Purpose                                 |
|--------------|-----------------------------------------|
| /add-feature | Start the workflow for adding a feature |
| /fix-bug     | Start the workflow for fixing a bug     |
| /write-test  | Start the workflow for writing tests    |
```
