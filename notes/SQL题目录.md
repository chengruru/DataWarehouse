# SQL题解

* 1.共同好友

题目描述：有两张表分别是用户信息表和用户关系表，具体的表结构如下所示：
用户信息表（user_info）：
| 用户ID | 用户名 |
| ------ | ------ |
| 1 | 小明 |
| 2 | 小红 |
| 3 | 小蓝 |

用户关系表（user_relationships）：
| 用户ID | 好朋友ID |
| ------ | ------ |
1 | 3
2 | 3

用户1和2有共同的朋友3。如何在一个查询中得到他的名字“小蓝”？

SQL题解：
```sql
select
     t2.user_id
    ,t2.user_name
from
(
    select 
        friend_id
    from user_relationships
    where user_id in (1, 2)
    group by friend_id
    having count(1) > 1
) t1 
left join
(
    select 
        user_id
        ,user_name
    from user_info
) t2 on t1.friend_id = t2.user_id
```