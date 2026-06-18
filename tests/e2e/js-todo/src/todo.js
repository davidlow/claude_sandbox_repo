'use strict';

/**
 * In-memory todo list.
 *
 * Currently has no persistence — all state lives in RAM and is lost when the
 * process exits.  This module is used as an E2E test fixture for the
 * claude-architect pipeline: Claude designs and implements a persistence layer
 * (file-based, SQLite, or similar) without changing the public API.
 */

class TodoList {
    constructor() {
        this._todos = [];
        this._nextId = 1;
    }

    /**
     * Add a new todo item.
     * @param {string} title - Non-empty title (required).
     * @param {string} [description=''] - Optional longer description.
     * @returns {object} The created todo object.
     */
    add(title, description = '') {
        if (!title || typeof title !== 'string' || !title.trim()) {
            throw new TypeError('title must be a non-empty string');
        }
        const todo = {
            id: this._nextId++,
            title: title.trim(),
            description: (description || '').trim(),
            done: false,
            createdAt: new Date().toISOString(),
            completedAt: null,
        };
        this._todos.push(todo);
        return { ...todo };
    }

    /**
     * Retrieve a todo by id.
     * @param {number} id
     * @returns {object|null} The todo or null if not found.
     */
    get(id) {
        const todo = this._todos.find(t => t.id === id);
        return todo ? { ...todo } : null;
    }

    /**
     * Mark a todo as completed.
     * @param {number} id
     * @returns {object} The updated todo.
     * @throws {Error} If the todo is not found.
     */
    complete(id) {
        const todo = this._todos.find(t => t.id === id);
        if (!todo) throw new Error(`Todo ${id} not found`);
        todo.done = true;
        todo.completedAt = new Date().toISOString();
        return { ...todo };
    }

    /**
     * Delete a todo.
     * @param {number} id
     * @returns {object} The deleted todo.
     * @throws {Error} If the todo is not found.
     */
    delete(id) {
        const idx = this._todos.findIndex(t => t.id === id);
        if (idx === -1) throw new Error(`Todo ${id} not found`);
        return { ...this._todos.splice(idx, 1)[0] };
    }

    /**
     * List todos, optionally filtered.
     * @param {object} [filter={}]
     * @param {boolean} [filter.done] - If provided, only return todos with this done state.
     * @returns {object[]} Shallow copies of matching todos.
     */
    list(filter = {}) {
        return this._todos
            .filter(t => {
                if (filter.done !== undefined && t.done !== filter.done) return false;
                return true;
            })
            .map(t => ({ ...t }));
    }

    /**
     * Return the count of todos.
     * @returns {number}
     */
    count() {
        return this._todos.length;
    }
}

module.exports = { TodoList };
