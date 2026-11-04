# 数据传输：SQLite 安全传输与图片预算

---

## 一、SQLite（WAL 模式）必须先 checkpoint

**这是本流程最高频的坑。** 表现：传到服务器后站点启动即报

```
database disk image is malformed
```

### 根因

SQLite 的 WAL 模式下，**最新数据在 `site.db-wal` 里**，主库 `site.db` 可能还是旧的。
单独复制 `site.db`（或三个文件分别在不同时间点复制）→ 主库与 WAL 失配 → 损坏。

### 三种正确做法

**做法 A（推荐）：先 checkpoint 再传**

```bash
# 在数据源机器
node -e "const {DatabaseSync}=require('node:sqlite');const d=new DatabaseSync('data/site.db');console.log(d.prepare('PRAGMA wal_checkpoint(TRUNCATE)').all())"
```

`TRUNCATE` 会把 WAL 内容合并进主库并清空 WAL。之后**只传 `site.db` 一个文件**即可。

校验：

```bash
node -e "const {DatabaseSync}=require('node:sqlite');const d=new DatabaseSync('data/site.db');console.log(d.prepare('PRAGMA integrity_check').get().integrity_check)"
# → ok
```

**做法 B：停服后三个文件一起传**

```bash
# 先停应用
pm2 stop web-app
# 三个文件必须来自同一时刻
cp data/site.db data/site.db-wal data/site.db-shm /dest/
pm2 start web-app
```

**做法 C：用 `sqlite3` 命令行**

```bash
sqlite3 data/site.db ".backup /dest/site.db"
```

> `.backup` 本身就是在线一致性快照，等价于 checkpoint。

### 校验清单

传完后**在目标机器上**再校验一次：

```bash
node -e "const {DatabaseSync}=require('node:sqlite');const d=new DatabaseSync('data/site.db');console.log(d.prepare('PRAGMA integrity_check').get().integrity_check);console.log(d.prepare('SELECT COUNT(*) c FROM projects').get().c)"
```

`integrity_check` 必须是 `ok`，行数要和源一致。

### ⚠️ 动手前先确认源库是好的

**别把一个已经损坏的库传出去。** 上游仓库里的 `site.db` 可能是坏的（被误提交过）。

```bash
node -e "const {DatabaseSync}=require('node:sqlite');try{const d=new DatabaseSync('data/site.db');console.log(d.prepare('PRAGMA integrity_check').get().integrity_check)}catch(e){console.log('BROKEN:',e.message)}"
```

发现损坏 → 找备份（`site.db.bak-*`、或另一份工作副本），不要试图抢救。

### 推论：代码副本和数据源可能是两个地方

实践中经常出现「代码在 GitHub 副本，数据库在另一个工作目录」的情况。
**代码取副本，数据取完好源** —— 别把两个来源混为一谈。

---

## 二、图片预算（`/data` 固定 20 GiB）

### 先算再传

不要全量上传。先统计**实际被引用**的文件：

```bash
# 从数据里解析所有图片引用路径
node -e "
const {DatabaseSync}=require('node:sqlite');
const d=new DatabaseSync('data/site.db');
const rows=d.prepare('SELECT json FROM projects').all();
const set=new Set();
for(const r of rows){
  const p=JSON.parse(r.json);
  if(p.coverImage) set.add(p.coverImage);
  for(const it of (p.media?.items||[])) if(it.src?.startsWith('/img/')) set.add(it.src);
}
console.log('引用文件数:', set.size);
" > refs.txt

# 算出实际需要的文件清单，复制成一份精简库
```

### 典型量级对比

| 方案 | 文件数 | 体积 | `/data` 占比（20 GiB） |
|---|---|---|---|
| 全量图片库 | 88,277 | 5.9 GB | 30% |
| **按实际引用裁剪** | 1,425 | 83 MB | **0.4%** |

**省 99%**。裁剪后 `/data` 总占用能控制在 5 GB 上下（应用 + 数据 + 图片 + 依赖 + 构建产物）。

### 裁剪时注意

- **零缺失**：裁剪后要验证每个引用都能命中文件
- **两种扩展名目录**：`/img/webp/<hash>.webp` 和 `/img/<hash>.<ext>` 走**两个不同目录**
  （`IMG_WEBP_DIR` / `IMG_DIR`），别放混
- 少数非 webp 原图要从另一个源目录补齐

### 布局约定

```
/data/home/<app>/              应用代码 + 数据
/data/home/<app>-data/imgs-webp   webp 线上图
/data/home/<app>-data/imgs        原图降级副本
```

目录名和 `.env` 里的 `IMG_WEBP_DIR` / `IMG_DIR` 必须一致。

---

## 三、大文件走 Release 分发

GitHub 单文件上限 100 MiB。超过的用 Release 附件：

```bash
# 打 tag 上传
gh release create v1.0-data site.db.gz articles.json.gz projects.json.gz

# 服务器侧下载
BASE=https://github.com/<owner>/<repo>/releases/download/v1.0-data
cd data
for f in site.db articles.json projects.json; do
  curl -L -o $f.gz $BASE/$f.gz && gzip -df $f.gz
done
```

**同 tag 同名替换**：删除旧附件再传新的，部署侧的下载地址不变，不用改脚本。

### Release 数据包更新流程（已实操）

1. `PRAGMA wal_checkpoint(TRUNCATE)` 合并 WAL
2. `gzip -9` 打三件套
3. 解压比对校验
4. API 删旧附件 → 传新附件

---

## 四、传输工具

### InstaBox CLI

```bash
instabox push <机器名> <本地目录>/ <远端目录> --all
instabox push <机器名> ./file.sh /data/home/file.sh
```

`--all` 表示包含所有文件。

### 大目录的替代方案

图片库很大时，分批传更稳：

```bash
# 分批：每次传一部分
for chunk in $(seq 0 4); do
  instabox push <机器名> ./imgs-part$chunk/ /data/home/<app>-data/imgs-webp --all
done
```

---

## 五、传输后必做的三项检查

```bash
# 1. 数据库完整性
node -e "const {DatabaseSync}=require('node:sqlite');const d=new DatabaseSync('data/site.db');console.log(d.prepare('PRAGMA integrity_check').get().integrity_check)"

# 2. 行数与源一致
node -e "const {DatabaseSync}=require('node:sqlite');const d=new DatabaseSync('data/site.db');console.log(d.prepare('SELECT COUNT(*) c FROM projects').get().c)"

# 3. 图片零缺失（逐个引用抽验）
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3000/img/webp/<某个hash>.webp
```

然后跑一遍应用自己的 QA 脚本（如果有），确认端到端可用。
