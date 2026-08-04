import EditorSyntax

/// One labelled snippet. `language` is what the sample *is* — ground truth,
/// not a snapshot of what the detector currently says. A nil language means the
/// sample is too ambiguous to act on and must not be detected confidently.
struct DetectionSample {
    let language: CodeLanguage?
    let name: String
    let code: String
}

/// A corpus of code the size and shape people actually paste into a note.
///
/// The detector is a weighted heuristic, so it will never score 100% here; the
/// point is to make its accuracy a measured number that a rewrite has to match
/// or beat, rather than 13 one-liners that any implementation passes.
enum DetectionCorpus {
    static let samples: [DetectionSample] = javascript + typescript + css + python + swift
        + html + json + shell + sql + rust + go + cpp + c + kotlin + csharp + java
        + php + dockerfile + ambiguous

    // MARK: - JavaScript

    private static let javascript: [DetectionSample] = [
        DetectionSample(language: .javascript, name: "js/async-fetch", code: #"""
        async function loadUser(id) {
          const response = await fetch(`/api/users/${id}`)
          if (!response.ok) throw new Error("request failed")
          return response.json()
        }
        """#),
        DetectionSample(language: .javascript, name: "js/class", code: #"""
        class Counter {
          constructor(start) {
            this.value = start
          }
          increment() {
            this.value += 1
            return this.value
          }
        }
        """#),
        DetectionSample(language: .javascript, name: "js/array-methods", code: #"""
        const totals = orders
          .filter(order => order.status === "paid")
          .map(order => order.amount)
          .reduce((sum, amount) => sum + amount, 0)
        console.log(totals)
        """#),
        DetectionSample(language: .javascript, name: "js/module", code: #"""
        const path = require("path")

        module.exports = function resolve(name) {
          return path.join(__dirname, name)
        }
        """#),
        DetectionSample(language: .javascript, name: "js/dom", code: #"""
        document.querySelectorAll(".row").forEach(function (row) {
          row.addEventListener("click", () => {
            window.location.hash = row.dataset.id
          })
        })
        """#),
        DetectionSample(language: .javascript, name: "js/promise-chain", code: #"""
        fetch("/api/config")
          .then(response => response.json())
          .then(config => {
            console.log(config.version)
          })
          .catch(error => console.error(error))
        """#),
        DetectionSample(language: .javascript, name: "js/destructuring", code: #"""
        const { host, port = 8080, ...rest } = options
        const [first, ...others] = items
        export default { host, port, rest, first, others }
        """#),
        DetectionSample(language: .javascript, name: "js/switch", code: #"""
        function describe(kind) {
          switch (kind) {
            case "a":
              return "first"
            case "b":
              return "second"
            default:
              return "unknown"
          }
        }
        """#),
        DetectionSample(language: .javascript, name: "js/generator", code: #"""
        function* take(iterable, count) {
          let taken = 0
          for (const value of iterable) {
            if (taken++ >= count) return
            yield value
          }
        }
        """#),
        DetectionSample(language: .javascript, name: "js/template-literal", code: #"""
        const greeting = (user) => `Hello, ${user.name}! You have ${user.count} messages.`
        console.log(greeting({ name: "Ada", count: 3 }))
        """#),
    ]

    // MARK: - TypeScript

    private static let typescript: [DetectionSample] = [
        DetectionSample(language: .typescript, name: "ts/interface", code: #"""
        interface User {
          id: number
          name: string
          active: boolean
        }

        function label(user: User): string {
          return user.name
        }
        """#),
        DetectionSample(language: .typescript, name: "ts/generics", code: #"""
        type Result<T> = { ok: true; value: T } | { ok: false; error: string }

        function unwrap<T>(result: Result<T>): T {
          if (!result.ok) throw new Error(result.error)
          return result.value
        }
        """#),
        DetectionSample(language: .typescript, name: "ts/enum-declare", code: #"""
        declare const VERSION: string

        enum Level {
          Debug = 0,
          Warn = 1,
          Error = 2,
        }

        export function log(level: Level, message: string): void {}
        """#),
        DetectionSample(language: .typescript, name: "ts/class-modifiers", code: #"""
        export class Store {
          private readonly items: string[] = []

          add(item: string): number {
            this.items.push(item)
            return this.items.length
          }
        }
        """#),
        DetectionSample(language: .typescript, name: "ts/namespace", code: #"""
        namespace Config {
          export interface Options {
            retries: number
            verbose: boolean
          }
        }
        """#),
        DetectionSample(language: .typescript, name: "ts/abstract-class", code: #"""
        abstract class Repository implements Closeable {
          protected abstract load(id: string): Promise<Buffer>

          async close(): Promise<void> {
            this.open = false
          }
        }
        """#),
        DetectionSample(language: .typescript, name: "ts/utility-types", code: #"""
        type Partial<T> = { [K in keyof T]?: T[K] }

        export type Handler = (event: string, payload: unknown) => void

        const handlers: Record<string, Handler> = {}
        """#),
        DetectionSample(language: .typescript, name: "ts/union-guard", code: #"""
        type Shape = Circle | Square

        function area(shape: Shape): number {
          if ("radius" in shape) {
            return Math.PI * shape.radius * shape.radius
          }
          return shape.side * shape.side
        }
        """#),
        DetectionSample(language: .typescript, name: "ts/async-typed", code: #"""
        export async function loadAll(ids: string[]): Promise<User[]> {
          const results: User[] = []
          for (const id of ids) {
            results.push(await loadOne(id))
          }
          return results
        }
        """#),
        DetectionSample(language: .typescript, name: "ts/readonly-props", code: #"""
        interface Props {
          readonly title: string
          readonly count: number
          onSelect?: (id: string) => void
        }

        declare function render(props: Props): void
        """#),
        DetectionSample(language: .typescript, name: "ts/decorators", code: #"""
        @Injectable()
        export class AuthService {
          constructor(private readonly http: HttpClient) {}

          login(user: string, password: string): boolean {
            return this.http.post("/login", { user, password })
          }
        }
        """#),
        DetectionSample(language: .typescript, name: "ts/keyof", code: #"""
        type Keys = keyof Options

        function pick<T, K extends keyof T>(source: T, keys: K[]): Pick<T, K> {
          const out = {} as Pick<T, K>
          for (const key of keys) out[key] = source[key]
          return out
        }
        """#),
        DetectionSample(language: .typescript, name: "ts/module-declare", code: #"""
        declare module "config" {
          export const endpoint: string
          export const timeout: number
          export function reload(): void
        }
        """#),
        DetectionSample(language: .typescript, name: "ts/typed-consts", code: #"""
        export const RETRIES: number = 3
        export const LABEL: string = "runner"
        export const VERBOSE: boolean = false

        export function configure(retries: number, verbose: boolean): void {}
        """#),
    ]

    // MARK: - CSS

    private static let css: [DetectionSample] = [
        DetectionSample(language: .css, name: "css/basic", code: #"""
        .card {
          background: #ffffff;
          border-radius: 8px;
          padding: 16px;
          color: #333;
        }
        """#),
        DetectionSample(language: .css, name: "css/media", code: #"""
        @media (max-width: 600px) {
          .sidebar {
            display: none;
          }
          .content {
            width: 100%;
          }
        }
        """#),
        DetectionSample(language: .css, name: "css/keyframes", code: #"""
        @keyframes fade {
          from { opacity: 0; }
          to { opacity: 1; }
        }

        .toast {
          animation: fade 200ms ease-out;
        }
        """#),
        DetectionSample(language: .css, name: "css/variables", code: #"""
        :root {
          --brand: #0a84ff;
          --gap: 12px;
        }

        .button {
          background: var(--brand);
          margin: var(--gap);
        }
        """#),
        DetectionSample(language: .css, name: "css/flex", code: #"""
        .row {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 8px;
        }
        """#),
        DetectionSample(language: .css, name: "css/grid", code: #"""
        .layout {
          display: grid;
          grid-template-columns: repeat(3, minmax(0, 1fr));
          grid-gap: 24px;
        }
        """#),
        DetectionSample(language: .css, name: "css/pseudo", code: #"""
        a:hover {
          text-decoration: underline;
        }

        li::marker {
          color: #888;
        }
        """#),
        DetectionSample(language: .css, name: "css/attribute-selector", code: #"""
        input[type="checkbox"] {
          accent-color: #0a84ff;
        }

        a[href^="https"] {
          font-weight: 600;
        }
        """#),
        DetectionSample(language: .css, name: "css/transition", code: #"""
        .panel {
          transform: translateY(-4px);
          transition: transform 150ms ease-in-out, opacity 150ms linear;
          will-change: transform;
        }
        """#),
        DetectionSample(language: .css, name: "css/supports-fontface", code: #"""
        @font-face {
          font-family: "Inter";
          src: url("/fonts/inter.woff2") format("woff2");
        }

        @supports (backdrop-filter: blur(4px)) {
          .bar {
            backdrop-filter: blur(4px);
          }
        }
        """#),
    ]

    // MARK: - Python

    private static let python: [DetectionSample] = [
        DetectionSample(language: .python, name: "py/function", code: #"""
        def normalize(values):
            """Scale values into 0..1."""
            low = min(values)
            high = max(values)
            return [(v - low) / (high - low) for v in values]
        """#),
        DetectionSample(language: .python, name: "py/class", code: #"""
        class Account:
            def __init__(self, owner):
                self.owner = owner
                self.balance = 0

            def deposit(self, amount):
                self.balance += amount
                return self.balance
        """#),
        DetectionSample(language: .python, name: "py/imports", code: #"""
        import os
        from pathlib import Path

        roots = [Path(p) for p in os.environ["PATHS"].split(":") if p]
        print(roots)
        """#),
        DetectionSample(language: .python, name: "py/try", code: #"""
        try:
            with open(path) as handle:
                data = handle.read()
        except FileNotFoundError:
            data = None
        finally:
            print("done")
        """#),
        DetectionSample(language: .python, name: "py/decorator", code: #"""
        @cache
        def fib(n):
            if n < 2:
                return n
            return fib(n - 1) + fib(n - 2)
        """#),
    ]

    // MARK: - Swift

    private static let swift: [DetectionSample] = [
        DetectionSample(language: .swift, name: "swift/struct", code: #"""
        struct Point {
            var x: Double
            var y: Double

            func distance(to other: Point) -> Double {
                let dx = x - other.x
                let dy = y - other.y
                return (dx * dx + dy * dy).squareRoot()
            }
        }
        """#),
        DetectionSample(language: .swift, name: "swift/protocol", code: #"""
        protocol Drawable {
            func draw(in rect: CGRect)
        }

        extension Drawable {
            func draw() {
                draw(in: .zero)
            }
        }
        """#),
        DetectionSample(language: .swift, name: "swift/guard", code: #"""
        func title(for id: String?) -> String {
            guard let id, !id.isEmpty else { return "untitled" }
            return id.uppercased()
        }
        """#),
        DetectionSample(language: .swift, name: "swift/enum-switch", code: #"""
        enum State {
            case idle
            case loading
            case failed(Error)
        }

        func describe(_ state: State) -> String {
            switch state {
            case .idle: return "idle"
            case .loading: return "loading"
            case .failed: return "failed"
            }
        }
        """#),
        DetectionSample(language: .swift, name: "swift/async", code: #"""
        @MainActor
        final class Loader {
            func load() async throws -> [String] {
                let (data, _) = try await URLSession.shared.data(from: url)
                return try JSONDecoder().decode([String].self, from: data)
            }
        }
        """#),
        DetectionSample(language: .swift, name: "swift/view", code: #"""
        struct ContentView: View {
            @State private var count = 0

            var body: some View {
                VStack {
                    Text("Tapped \(count) times")
                    Button("Tap") { count += 1 }
                }
            }
        }
        """#),
        DetectionSample(language: .swift, name: "swift/do-catch", code: #"""
        func save(_ data: Data) {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                print("save failed: \(error)")
            }
        }
        """#),
        DetectionSample(language: .swift, name: "swift/computed", code: #"""
        extension Array where Element: Comparable {
            var sortedDescending: [Element] {
                sorted(by: >)
            }

            mutating func keepTop(_ n: Int) {
                self = Array(sortedDescending.prefix(n))
            }
        }
        """#),
        DetectionSample(language: .swift, name: "swift/generics", code: #"""
        func firstMatch<T: Equatable>(of needle: T, in haystack: [T]) -> Int? {
            for (index, value) in haystack.enumerated() where value == needle {
                return index
            }
            return nil
        }
        """#),
        DetectionSample(language: .swift, name: "swift/closures", code: #"""
        let names = people
            .filter { $0.age >= 18 }
            .map { $0.name.uppercased() }
            .sorted()

        print(names.joined(separator: ", "))
        """#),
    ]

    // MARK: - HTML

    private static let html: [DetectionSample] = [
        DetectionSample(language: .html, name: "html/page", code: #"""
        <!DOCTYPE html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <title>Example</title>
          </head>
          <body>
            <h1>Hello</h1>
          </body>
        </html>
        """#),
        DetectionSample(language: .html, name: "html/form", code: #"""
        <form action="/search" method="get">
          <label for="q">Search</label>
          <input id="q" name="q" type="text" placeholder="Type here">
          <button type="submit">Go</button>
        </form>
        """#),
        DetectionSample(language: .html, name: "html/table", code: #"""
        <table class="data">
          <thead>
            <tr><th>Name</th><th>Count</th></tr>
          </thead>
          <tbody>
            <tr><td>Widgets</td><td>12</td></tr>
          </tbody>
        </table>
        """#),
        DetectionSample(language: .html, name: "html/nested", code: #"""
        <div class="card">
          <div class="card-header">
            <span class="title">Report</span>
          </div>
          <div class="card-body">
            <p>Everything looks fine.</p>
          </div>
        </div>
        """#),
        DetectionSample(language: .html, name: "html/links", code: #"""
        <nav>
          <ul>
            <li><a href="#top">Top</a></li>
            <li><a href="/about">About</a></li>
          </ul>
        </nav>
        """#),
    ]

    // MARK: - JSON

    private static let json: [DetectionSample] = [
        DetectionSample(language: .json, name: "json/object", code: #"""
        {
          "name": "example",
          "version": "1.4.0",
          "private": true
        }
        """#),
        DetectionSample(language: .json, name: "json/array", code: #"""
        [
          { "id": 1, "label": "first" },
          { "id": 2, "label": "second" },
          { "id": 3, "label": "third" }
        ]
        """#),
        DetectionSample(language: .json, name: "json/config", code: #"""
        {
          "compilerOptions": {
            "target": "es2020",
            "strict": true,
            "outDir": "dist"
          },
          "include": ["src"]
        }
        """#),
        DetectionSample(language: .json, name: "json/nested", code: #"""
        {
          "user": {
            "id": 42,
            "roles": ["admin", "editor"],
            "profile": { "city": "Lisbon", "active": false }
          }
        }
        """#),
        DetectionSample(language: .json, name: "json/numbers", code: #"""
        {
          "min": -3.5,
          "max": 128,
          "ratios": [0.25, 0.5, 0.75],
          "label": null
        }
        """#),
    ]

    // MARK: - Shell

    private static let shell: [DetectionSample] = [
        DetectionSample(language: .shell, name: "sh/shebang-loop", code: #"""
        #!/bin/bash
        for file in *.txt; do
          echo "processing $file"
          wc -l "$file"
        done
        """#),
        DetectionSample(language: .shell, name: "sh/case", code: #"""
        case "$1" in
          start) echo "starting" ;;
          stop) echo "stopping" ;;
          *) echo "usage: $0 {start|stop}" ;;
        esac
        """#),
        DetectionSample(language: .shell, name: "sh/function", code: #"""
        #!/usr/bin/env sh
        retry() {
          n=0
          until [ $n -ge 3 ]; do
            "$@" && return 0
            n=$((n + 1))
          done
          return 1
        }
        """#),
        DetectionSample(language: .shell, name: "sh/pipeline", code: #"""
        if grep -q "ERROR" "$LOGFILE"; then
          tail -n 50 "$LOGFILE" | sort | uniq -c
        else
          echo "clean"
        fi
        """#),
        DetectionSample(language: .shell, name: "sh/env", code: #"""
        export PATH="$HOME/.local/bin:$PATH"
        export EDITOR=vim
        alias ll="ls -lah"
        """#),
    ]

    // MARK: - SQL

    private static let sql: [DetectionSample] = [
        DetectionSample(language: .sql, name: "sql/select-join", code: #"""
        SELECT u.id, u.name, COUNT(o.id) AS orders
        FROM users u
        JOIN orders o ON o.user_id = u.id
        WHERE u.active = true
        GROUP BY u.id, u.name;
        """#),
        DetectionSample(language: .sql, name: "sql/create-table", code: #"""
        CREATE TABLE sessions (
          id UUID PRIMARY KEY,
          user_id INTEGER NOT NULL,
          created_at TIMESTAMP DEFAULT now()
        );
        """#),
        DetectionSample(language: .sql, name: "sql/insert-update", code: #"""
        INSERT INTO totals (day, amount) VALUES ('2024-01-01', 10);
        UPDATE totals SET amount = amount + 5 WHERE day = '2024-01-01';
        """#),
        DetectionSample(language: .sql, name: "sql/cte", code: #"""
        WITH recent AS (
          SELECT id FROM events WHERE created_at > now() - interval '7 days'
        )
        SELECT COUNT(*) FROM recent;
        """#),
        DetectionSample(language: .sql, name: "sql/delete", code: #"""
        DELETE FROM cache
        WHERE expires_at < now()
          AND key NOT IN (SELECT key FROM pinned);
        """#),
    ]

    // MARK: - Rust

    private static let rust: [DetectionSample] = [
        DetectionSample(language: .rust, name: "rust/main", code: #"""
        fn main() {
            let mut total = 0;
            for value in 1..=10 {
                total += value;
            }
            println!("{}", total);
        }
        """#),
        DetectionSample(language: .rust, name: "rust/struct-impl", code: #"""
        pub struct Counter {
            value: usize,
        }

        impl Counter {
            pub fn new() -> Self {
                Counter { value: 0 }
            }
        }
        """#),
        DetectionSample(language: .rust, name: "rust/trait", code: #"""
        trait Shape {
            fn area(&self) -> f64;
        }

        impl Shape for Circle {
            fn area(&self) -> f64 {
                3.14 * self.r * self.r
            }
        }
        """#),
        DetectionSample(language: .rust, name: "rust/match", code: #"""
        fn label(value: Option<String>) -> String {
            match value {
                Some(text) => text,
                None => String::from("empty"),
            }
        }
        """#),
        DetectionSample(language: .rust, name: "rust/derive", code: #"""
        #[derive(Debug, Clone)]
        pub struct Config {
            pub names: Vec<String>,
            pub retries: usize,
        }
        """#),
    ]

    // MARK: - Go

    private static let go: [DetectionSample] = [
        DetectionSample(language: .go, name: "go/main", code: #"""
        package main

        import "fmt"

        func main() {
            total := 0
            for i := 1; i <= 10; i++ {
                total += i
            }
            fmt.Println(total)
        }
        """#),
        DetectionSample(language: .go, name: "go/struct", code: #"""
        package models

        type User struct {
            ID   int
            Name string
        }

        func (u User) Label() string {
            return u.Name
        }
        """#),
        DetectionSample(language: .go, name: "go/errors", code: #"""
        func load(path string) ([]byte, error) {
            data, err := os.ReadFile(path)
            if err != nil {
                return nil, fmt.Errorf("read %s: %w", path, err)
            }
            return data, nil
        }
        """#),
        DetectionSample(language: .go, name: "go/imports", code: #"""
        package main

        import (
            "fmt"
            "os"
            "strings"
        )

        func main() {
            fmt.Println(strings.ToUpper(os.Args[1]))
        }
        """#),
        DetectionSample(language: .go, name: "go/channel", code: #"""
        func worker(jobs <-chan int, results chan<- int) {
            for job := range jobs {
                results <- job * 2
            }
        }
        """#),
    ]

    // MARK: - C++

    private static let cpp: [DetectionSample] = [
        DetectionSample(language: .cpp, name: "cpp/iostream", code: #"""
        #include <iostream>

        int main() {
            std::cout << "hello" << std::endl;
            return 0;
        }
        """#),
        DetectionSample(language: .cpp, name: "cpp/class", code: #"""
        #include <string>

        class Person {
        public:
            Person(std::string name) : name_(name) {}
            std::string name() const { return name_; }
        private:
            std::string name_;
        };
        """#),
        DetectionSample(language: .cpp, name: "cpp/template", code: #"""
        template <typename T>
        T maximum(T a, T b) {
            return a > b ? a : b;
        }
        """#),
        DetectionSample(language: .cpp, name: "cpp/vector", code: #"""
        #include <vector>
        #include <algorithm>

        void sortAll(std::vector<int>& values) {
            std::sort(values.begin(), values.end());
        }
        """#),
        DetectionSample(language: .cpp, name: "cpp/nullptr", code: #"""
        namespace util {
            Node* find(Node* head, int key) {
                while (head != nullptr && head->key != key) {
                    head = head->next;
                }
                return head;
            }
        }
        """#),
    ]

    // MARK: - C

    private static let c: [DetectionSample] = [
        DetectionSample(language: .c, name: "c/printf", code: #"""
        #include <stdio.h>

        int main(void) {
            printf("hello\n");
            return 0;
        }
        """#),
        DetectionSample(language: .c, name: "c/malloc", code: #"""
        #include <stdlib.h>

        int *make_array(int n) {
            int *values = malloc(n * sizeof(int));
            if (values == NULL) return NULL;
            return values;
        }
        """#),
        DetectionSample(language: .c, name: "c/typedef", code: #"""
        #include <stdio.h>

        typedef struct {
            int x;
            int y;
        } Point;

        void print_point(Point p) {
            printf("%d %d\n", p.x, p.y);
        }
        """#),
        DetectionSample(language: .c, name: "c/loop", code: #"""
        #include <stdio.h>

        int main() {
            int total = 0;
            for (int i = 0; i < 10; i++) {
                total += i;
            }
            printf("%d\n", total);
            return 0;
        }
        """#),
        DetectionSample(language: .c, name: "c/string", code: #"""
        #include <string.h>
        #include <stdio.h>

        int main(int argc, char **argv) {
            if (argc > 1 && strcmp(argv[1], "-v") == 0) {
                printf("verbose\n");
            }
            return 0;
        }
        """#),
    ]

    // MARK: - Kotlin

    private static let kotlin: [DetectionSample] = [
        DetectionSample(language: .kotlin, name: "kt/data-class", code: #"""
        package com.example.model

        data class User(
            val id: Int,
            val name: String,
            val active: Boolean = true
        )
        """#),
        DetectionSample(language: .kotlin, name: "kt/main", code: #"""
        fun main() {
            val names = listOf("Ada", "Grace", "Alan")
            for (name in names) {
                println("Hello, $name")
            }
        }
        """#),
        DetectionSample(language: .kotlin, name: "kt/when", code: #"""
        fun describe(value: Int): String = when {
            value < 0 -> "negative"
            value == 0 -> "zero"
            else -> "positive"
        }
        """#),
        DetectionSample(language: .kotlin, name: "kt/class-companion", code: #"""
        class Counter private constructor(private var value: Int) {
            fun increment(): Int {
                value += 1
                return value
            }

            companion object {
                fun zero() = Counter(0)
            }
        }
        """#),
        DetectionSample(language: .kotlin, name: "kt/sealed", code: #"""
        sealed class Result {
            object Loading : Result()
            data class Success(val body: String) : Result()
            data class Failure(val error: Throwable) : Result()
        }
        """#),
        DetectionSample(language: .kotlin, name: "kt/coroutines", code: #"""
        suspend fun loadAll(ids: List<String>): List<User> = coroutineScope {
            ids.map { id ->
                async { load(id) }
            }.awaitAll()
        }
        """#),
        DetectionSample(language: .kotlin, name: "kt/extension", code: #"""
        fun String.titlecase(): String {
            if (isEmpty()) return this
            return substring(0, 1).uppercase() + substring(1).lowercase()
        }
        """#),
        DetectionSample(language: .kotlin, name: "kt/interface-override", code: #"""
        interface Repository {
            fun load(id: String): String?
        }

        class InMemoryRepository : Repository {
            private val store = mutableMapOf<String, String>()

            override fun load(id: String): String? = store[id]
        }
        """#),
        DetectionSample(language: .kotlin, name: "kt/lateinit", code: #"""
        class Service {
            lateinit var client: HttpClient

            fun start() {
                client = HttpClient()
            }
        }
        """#),
        DetectionSample(language: .kotlin, name: "kt/lambda", code: #"""
        val totals = orders
            .filter { it.status == "paid" }
            .map { it.amount }
            .sum()

        println(totals)
        """#),
    ]

    // MARK: - C#

    private static let csharp: [DetectionSample] = [
        DetectionSample(language: .csharp, name: "cs/hello", code: #"""
        using System;

        class Program
        {
            static void Main(string[] args)
            {
                Console.WriteLine("Hello, world");
            }
        }
        """#),
        DetectionSample(language: .csharp, name: "cs/properties", code: #"""
        namespace Example.Models
        {
            public class User
            {
                public int Id { get; set; }
                public string Name { get; set; }
                public bool IsActive { get; set; }
            }
        }
        """#),
        DetectionSample(language: .csharp, name: "cs/linq", code: #"""
        using System.Linq;
        using System.Collections.Generic;

        var paid = orders.Where(o => o.Status == "paid").Select(o => o.Amount).ToList();
        Console.WriteLine(paid.Sum());
        """#),
        DetectionSample(language: .csharp, name: "cs/foreach", code: #"""
        foreach (var item in items)
        {
            if (item.Count > 0)
            {
                Console.WriteLine($"{item.Name}: {item.Count}");
            }
        }
        """#),
        DetectionSample(language: .csharp, name: "cs/async", code: #"""
        using System.Threading.Tasks;

        public async Task<string> LoadAsync(string id)
        {
            var response = await _client.GetAsync(id);
            return await response.Content.ReadAsStringAsync();
        }
        """#),
        DetectionSample(language: .csharp, name: "cs/interface", code: #"""
        using System;

        public interface IRepository : IDisposable
        {
            string Load(string id);
        }

        public class Repository : IRepository
        {
            public string Load(string id) => _store[id];
            public void Dispose() { }
        }
        """#),
        DetectionSample(language: .csharp, name: "cs/attributes", code: #"""
        using System;

        [Serializable]
        public partial class Settings
        {
            [Obsolete("use Endpoint")]
            public string Url { get; set; }

            public string Endpoint { get; set; }
        }
        """#),
        DetectionSample(language: .csharp, name: "cs/generics", code: #"""
        using System.Collections.Generic;

        public class Cache<TKey, TValue>
        {
            private readonly Dictionary<TKey, TValue> _items = new();

            public IEnumerable<TKey> Keys => _items.Keys;
        }
        """#),
        DetectionSample(language: .csharp, name: "cs/switch-expression", code: #"""
        using System;

        static string Describe(int value) => value switch
        {
            < 0 => "negative",
            0 => "zero",
            _ => "positive"
        };
        """#),
        DetectionSample(language: .csharp, name: "cs/verbatim-string", code: #"""
        using System.IO;

        var root = @"C:\Users\Public\Documents";
        foreach (var path in Directory.GetFiles(root))
        {
            Console.WriteLine(Path.GetFileName(path));
        }
        """#),
    ]

    // MARK: - Java

    private static let java: [DetectionSample] = [
        DetectionSample(language: .java, name: "java/hello", code: #"""
        public class Main {
            public static void main(String[] args) {
                System.out.println("Hello, world");
            }
        }
        """#),
        DetectionSample(language: .java, name: "java/package", code: #"""
        package com.example.model;

        public class User {
            private final String name;

            public User(String name) {
                this.name = name;
            }
        }
        """#),
        DetectionSample(language: .java, name: "java/collections", code: #"""
        import java.util.ArrayList;
        import java.util.List;

        List<String> names = new ArrayList<>();
        names.add("Ada");
        names.add("Grace");
        """#),
        DetectionSample(language: .java, name: "java/interface", code: #"""
        package com.example;

        public interface Repository {
            String load(String id) throws Exception;
        }
        """#),
        DetectionSample(language: .java, name: "java/override", code: #"""
        public class Runner implements Runnable {
            @Override
            public void run() {
                System.out.println("running");
            }
        }
        """#),
        DetectionSample(language: .java, name: "java/map", code: #"""
        import java.util.HashMap;
        import java.util.Map;

        Map<String, Integer> counts = new HashMap<>();
        for (String word : words) {
            counts.merge(word, 1, Integer::sum);
        }
        """#),
        DetectionSample(language: .java, name: "java/try", code: #"""
        import java.io.IOException;

        public String read(String path) throws IOException {
            try {
                return Files.readString(Path.of(path));
            } catch (IOException e) {
                return null;
            }
        }
        """#),
        DetectionSample(language: .java, name: "java/builder", code: #"""
        StringBuilder builder = new StringBuilder();
        for (String part : parts) {
            builder.append(part).append(", ");
        }
        System.out.println(builder.toString());
        """#),
        DetectionSample(language: .java, name: "java/enum", code: #"""
        package com.example;

        public enum Level {
            DEBUG,
            WARN,
            ERROR;

            public boolean isSevere() {
                return this == ERROR;
            }
        }
        """#),
        DetectionSample(language: .java, name: "java/synchronized", code: #"""
        public class Counter {
            private int value = 0;

            public synchronized int increment() {
                value += 1;
                return value;
            }
        }
        """#),
    ]

    // MARK: - PHP

    private static let php: [DetectionSample] = [
        DetectionSample(language: .php, name: "php/open-tag", code: #"""
        <?php

        $name = "Ada";
        echo "Hello, " . $name;
        """#),
        DetectionSample(language: .php, name: "php/class", code: #"""
        <?php

        class User
        {
            private $name;

            public function __construct($name)
            {
                $this->name = $name;
            }

            public function getName()
            {
                return $this->name;
            }
        }
        """#),
        DetectionSample(language: .php, name: "php/namespace-use", code: #"""
        namespace App\Http\Controllers;

        use App\Models\User;
        use Illuminate\Http\Request;

        class UserController extends Controller
        {
            public function index(Request $request)
            {
                return User::all();
            }
        }
        """#),
        DetectionSample(language: .php, name: "php/foreach", code: #"""
        $totals = [];
        foreach ($orders as $order) {
            $totals[] = $order->amount;
        }
        echo array_sum($totals);
        """#),
        DetectionSample(language: .php, name: "php/array", code: #"""
        $config = [
            'host' => 'localhost',
            'port' => 8080,
            'debug' => true,
        ];

        if (isset($config['host'])) {
            echo $config['host'];
        }
        """#),
        DetectionSample(language: .php, name: "php/superglobal", code: #"""
        <?php
        if ($_SERVER['REQUEST_METHOD'] === 'POST') {
            $email = $_POST['email'];
            var_dump($email);
        }
        """#),
        DetectionSample(language: .php, name: "php/function", code: #"""
        function normalize($values)
        {
            $out = [];
            foreach ($values as $value) {
                $out[] = trim(strtolower($value));
            }
            return $out;
        }
        """#),
        DetectionSample(language: .php, name: "php/require", code: #"""
        <?php
        require_once __DIR__ . '/vendor/autoload.php';

        $app = new Application();
        $app->run();
        """#),
        DetectionSample(language: .php, name: "php/elseif", code: #"""
        if ($count > 10) {
            $label = 'many';
        } elseif ($count > 0) {
            $label = 'some';
        } else {
            $label = 'none';
        }
        """#),
        DetectionSample(language: .php, name: "php/interface", code: #"""
        <?php

        interface Repository
        {
            public function load(string $id): ?string;
        }
        """#),
    ]

    // MARK: - Dockerfile

    private static let dockerfile: [DetectionSample] = [
        DetectionSample(language: .dockerfile, name: "docker/node", code: #"""
        FROM node:20-alpine

        WORKDIR /app
        COPY package*.json ./
        RUN npm ci --omit=dev
        COPY . .
        EXPOSE 3000
        CMD ["node", "server.js"]
        """#),
        DetectionSample(language: .dockerfile, name: "docker/multistage", code: #"""
        FROM golang:1.22 AS build
        WORKDIR /src
        COPY . .
        RUN go build -o /out/app ./cmd/app

        FROM gcr.io/distroless/base
        COPY --from=build /out/app /app
        ENTRYPOINT ["/app"]
        """#),
        DetectionSample(language: .dockerfile, name: "docker/python", code: #"""
        FROM python:3.12-slim

        ENV PYTHONUNBUFFERED=1
        WORKDIR /srv
        COPY requirements.txt .
        RUN pip install --no-cache-dir -r requirements.txt
        COPY . .
        CMD ["python", "-m", "app"]
        """#),
        DetectionSample(language: .dockerfile, name: "docker/args", code: #"""
        FROM debian:bookworm

        ARG VERSION=1.0.0
        LABEL org.opencontainers.image.version=$VERSION

        RUN apt-get update && apt-get install -y curl
        USER nobody
        """#),
        DetectionSample(language: .dockerfile, name: "docker/healthcheck", code: #"""
        FROM nginx:alpine

        COPY nginx.conf /etc/nginx/nginx.conf
        EXPOSE 80
        HEALTHCHECK --interval=30s CMD curl -f http://localhost/ || exit 1
        STOPSIGNAL SIGQUIT
        """#),
    ]

    // MARK: - Ambiguous

    /// Too little signal to switch a code block's highlighting on. These must
    /// not come back confident — a wrong confident guess is worse than none.
    private static let ambiguous: [DetectionSample] = [
        DetectionSample(language: nil, name: "amb/assignment", code: "x = 1"),
        DetectionSample(language: nil, name: "amb/prose", code: "hello world"),
        DetectionSample(language: nil, name: "amb/sentence", code:
            "The quick brown fox jumps over the lazy dog."),
        DetectionSample(language: nil, name: "amb/todo", code: "TODO: fix this later"),
        DetectionSample(language: nil, name: "amb/numbers", code: "1 2 3 4 5"),
        DetectionSample(language: nil, name: "amb/call", code: "a.b(c)"),
        DetectionSample(language: nil, name: "amb/blank", code: "   "),
        DetectionSample(language: nil, name: "amb/word", code: "total"),
    ]
}
