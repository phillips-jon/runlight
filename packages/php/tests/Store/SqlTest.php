<?php

declare(strict_types=1);

namespace Runlight\Tests\Store;

use PHPUnit\Framework\TestCase;
use Runlight\Store\Sql;
use Runlight\Store\Stores;

/** The SQL store.ts builds, and how the MySQL driver rewrites it (mysql.test.ts). */
final class SqlTest extends TestCase
{
    public function testValuesFillPlaceholdersOutsideQuotesOnlyNamesAreQuotedWithBackticksAndBackslashesStayLiteral(): void
    {
        $escape = static fn (mixed $value): string => is_string($value) ? "'$value'" : ($value === null ? 'null' : (string) $value);
        $this->assertSame(
            "SELECT `key`, 'x' FROM t WHERE a = '?' AND b LIKE 2 ESCAPE '\\\\' AND c = null",
            Stores::mysqlText("SELECT \"key\", ? FROM t WHERE a = '?' AND b LIKE ? ESCAPE '\\' AND c = ?", ['x', 2, null], $escape),
        );
        $this->assertSame("SELECT 'it\\'s', NULL, 1.5, 'a\\\\b'", Stores::mysqlText('SELECT ?, ?, ?, ?', ["it's", null, 1.5, 'a\\b']), "mysql2's own escaping");
        $this->assertSame('SELECT `a``b`', Stores::mysqlText('SELECT "a`b"'));
        try {
            Stores::mysqlText('SELECT ?, ?', [1]);
            $this->fail('more placeholders');
        } catch (\InvalidArgumentException $error) {
            $this->assertStringContainsString('more placeholders', $error->getMessage());
        }
        try {
            Stores::mysqlText('SELECT ?', [1, 2]);
            $this->fail('more values');
        } catch (\InvalidArgumentException $error) {
            $this->assertStringContainsString('more values', $error->getMessage());
        }
    }

    public function testPatterns(): void
    {
        $this->assertSame('/blog/*/[[]x[?]]', Sql::globPattern('/blog/*/[x?]'));
        $this->assertSame('/blog/%/50\\%\\_\\\\', Sql::likePattern('/blog/*/50%_\\'));
        $this->assertSame('*[üÜ][bB][eE][rR] [[][*][?]1ß*', Sql::anyCase('Über [*?1ß'));
        $this->assertSame('*😀[éÉ]*', Sql::anyCase('😀é'));
    }

    public function testUpsertsAreWrittenEachDatabasesWay(): void
    {
        $this->assertSame('INSERT INTO rl_salts (day, salt) VALUES (?, ?) ON CONFLICT (day) DO NOTHING', Sql::upsert('sqlite', 'rl_salts', ['day', 'salt'], ['day'], []));
        $this->assertSame('INSERT INTO rl_salts (day, salt) VALUES (?, ?) ON DUPLICATE KEY UPDATE day = day', Sql::upsert('mysql', 'rl_salts', ['day', 'salt'], ['day'], []));
        $this->assertSame('INSERT INTO rl_meta ("key", value) VALUES (?, ?) ON CONFLICT ("key") DO UPDATE SET value = excluded.value', Sql::upsert('postgres', 'rl_meta', ['"key"', 'value'], ['"key"'], ['value']));
        $this->assertSame('INSERT INTO rl_meta ("key", value) VALUES (?, ?) ON DUPLICATE KEY UPDATE value = VALUES(value)', Sql::upsert('mysql', 'rl_meta', ['"key"', 'value'], ['"key"'], ['value']));
        $this->assertSame('(s.started_at DIV 900000)', Sql::div('mysql', 's.started_at', 900000));
        $this->assertSame('(s.started_at / 900000)', Sql::div('postgres', 's.started_at', 900000));
        $this->assertSame('CAST(? AS CHAR)', Sql::asText('mysql', '?'));
        $this->assertSame('VALUES (CAST(? AS INTEGER), CAST(? AS BIGINT), CAST(? AS BIGINT)), (?, ?, ?)', Sql::bucketTable('postgres', [['start' => 0, 'end' => 1], ['start' => 1, 'end' => 2]]));
        $this->assertSame('SELECT ? AS i, ? AS bs, ? AS be UNION ALL SELECT ?, ?, ?', Sql::bucketTable('mysql', [['start' => 0, 'end' => 1], ['start' => 1, 'end' => 2]]));
    }

    public function testFiltersBecomeConditions(): void
    {
        $f = static fn (string $d, string $op, string $v): array => ['dimension' => $d, 'op' => $op, 'value' => $v];
        $this->assertSame(['sql' => 'e.path = ?', 'params' => ['/caf%C3%A9']], Sql::condition($f('page', 'is', '/café'), 'sqlite'));
        $this->assertSame(['sql' => 's.entry_path = ?', 'params' => ['/x']], Sql::condition($f('entry', 'not', '/x'), 'sqlite', true));
        $this->assertSame(['sql' => 's.country <> ?', 'params' => ['GB']], Sql::condition($f('country', 'not', 'GB'), 'postgres'));
        $this->assertSame(['sql' => 's.source GLOB ?', 'params' => ['*[gG][oO]*']], Sql::condition($f('source', 'contains', 'go'), 'sqlite'));
        $this->assertSame(['sql' => "LOWER(s.source) LIKE ? ESCAPE '\\'", 'params' => ['%g\\_o%']], Sql::condition($f('source', 'contains', 'G_o'), 'mysql'));
        // A path in its given, lower, upper, and title case, each encoded.
        $this->assertSame(
            ['sql' => "(e.path LIKE ? ESCAPE '\\' OR e.path LIKE ? ESCAPE '\\' OR e.path LIKE ? ESCAPE '\\' OR e.path LIKE ? ESCAPE '\\')", 'params' => ['%\\%C3\\%BCBER-uns%', '%\\%C3\\%BCber-uns%', '%\\%C3\\%9CBER-UNS%', '%\\%C3\\%9Cber-Uns%']],
            Sql::condition($f('page', 'contains', 'üBER-uns'), 'sqlite'),
        );
        $scope = Sql::visitScope([$f('event', 'not', 'Signup'), $f('country', 'is', 'GB')], 'default', 10, 20, 'postgres');
        $this->assertSame(" AND NOT EXISTS (SELECT 1 FROM rl_events e WHERE e.site = ? AND e.ts >= ? AND e.ts < ? AND e.kind = 'event' AND e.name = ? AND e.session = s.id) AND s.country = ?", $scope['sql']);
        $this->assertSame(['default', 10, 20 + Sql::EVENT_TAIL_MS, 'Signup', 'GB'], $scope['params']);
        $this->assertNull(Sql::pageviewsOf([$f('country', 'is', 'GB'), $f('page', 'not', '/x')], 'default', 0, 1, 'sqlite'));
        $this->assertSame(['default', 0, 1 + Sql::EVENT_TAIL_MS, '/a', '/b', 'h'], Sql::pageviewsOf([$f('page', 'is', '/a'), $f('page', 'is', '/b'), $f('hostname', 'is', 'h')], 'default', 0, 1, 'sqlite')['params']);
    }

    public function testTextIsOrderedByCodePoint(): void
    {
        $values = ['b', 'a ', 'A', "\u{FFFD}", "\u{1F600}", 'a', 'é'];
        usort($values, Sql::codeOrder(...));
        $this->assertSame(['A', 'a', 'a ', 'b', 'é', "\u{FFFD}", "\u{1F600}"], $values, 'an emoji after U+FFFD, as code points order them and UTF-16 units do not');
    }
}
